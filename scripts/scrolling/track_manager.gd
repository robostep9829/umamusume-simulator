class_name TrackManager
extends Node3D

## Track composer that chains consecutive floor elements to build a track.
##
## The track's shape is not baked in: it is the sequence of elements (straights
## and turns) chained end to end, so curvature emerges from placing consecutive
## curved elements. Two modes share the same pool of recycled segments:
##   - Closed loop: a finite `TrackLevel` whose sequence wraps, recycles around
##     the player via a precomputed spine (coordinates stay bounded).
##   - Infinite: a procedural `InfiniteTrackLevel` with varying curvature; a
##     moving scroll origin and player snap keep coordinates from growing.
##
## The track itself knows nothing about scenery: it announces every floor body it
## places through `segment_placed`, and systems such as [BiomeDirector] hang off
## that signal.

enum Kind { STRAIGHT, TURN }

## Emitted for every floor body that was (re)placed, after its transform, mesh and
## collider are set. `element_index` identifies the piece of track the body now
## shows - endless tracks count elements from the start of the level, a closed
## loop counts them inside the lap - so the same piece always reports the same
## index, whichever pooled body happens to host it. That is what lets listeners
## rebuild only what actually changed.
signal segment_placed(element_index: int, body: StaticBody3D, segment: TrackSegment)

## Player the track is centred on and recycled around.
@export var player: Node3D

## Finite element sequence for closed-loop mode (ignored when `infinite` is on).
## If left null, a default `closed_racetrack(20, 18)` is built.
@export var track_level: TrackLevel

## Straight segment resource (mesh + geometry). If left null, the default
## `straight_segment.tres` is loaded.
@export var straight_segment: TrackSegment
## Curved (left-turn) segment resource. If left null, the default
## `turn_segment.tres` is loaded. The right-turn variant is derived from it.
@export var turn_segment: TrackSegment
## Number of recycled segment instances; a larger window covers more track
## ahead of the player at the cost of more bodies.
@export var pool_size: int = 40

## Infinite mode. When on, the track is generated procedurally from a seed with
## varying curvature, reusing a moving scroll origin instead of a finite level.
@export var infinite: bool = false
## Seed for the procedural infinite track generator.
@export var infinite_seed: int = 0
## Minimum number of straight segments in each infinite section.
@export var straight_min: int = 10
## Maximum number of straight segments in each infinite section.
@export var straight_max: int = 30
## Minimum number of curved segments in each infinite section.
@export var turn_min: int = 6
## Maximum number of curved segments in each infinite section.
@export var turn_max: int = 18
## World distance the scroll origin may drift before the player and track are
## snapped back toward the world origin to keep coordinates bounded.
@export var snap_distance: float = 6000.0

var _straight_segment: TrackSegment
var _turn_segment: TrackSegment
var _turn_right_segment: TrackSegment
var _seg_length: float
var _straight_shape: BoxShape3D
var _turn_shape: BoxShape3D

# Closed-loop state
var _slot_count: int = 0
var _lap_length: float = 0.0
var _spine_kind: Array[int] = []
var _spine_transform: Array[Transform3D] = []
var _spine_pt: PackedVector3Array = []

# Infinite state
var _infinite_level: InfiniteTrackLevel
var _scroll: Node3D
var _slot_first: int = 0
var _window_kind: Array[int] = []
var _window_tf: Array[Transform3D] = []
var _window_pt: PackedVector3Array = []

var _pool: Array[StaticBody3D] = []


func _ready() -> void:
	if track_level == null:
		track_level = TrackLevel.closed_racetrack(20, 18)
	if straight_segment == null:
		straight_segment = load("res://worlds/scrolling_track/floor_segments/straight_segment.tres")
	if turn_segment == null:
		turn_segment = load("res://worlds/scrolling_track/floor_segments/turn_segment.tres")

	_straight_segment = straight_segment
	_turn_segment = turn_segment
	_turn_right_segment = turn_segment.duplicate()
	_turn_right_segment.direction = 1
	_seg_length = straight_segment.length

	_straight_shape = BoxShape3D.new()
	_straight_shape.size = _collider_size(straight_segment, 0.0, 0.0)
	_turn_shape = BoxShape3D.new()
	_turn_shape.size = _collider_size(turn_segment, 10.0, 1.0)

	if infinite:
		_init_infinite()
	else:
		_build_spine()
		_create_pool(self)
		_replenish(0.0)


func _physics_process(_delta: float) -> void:
	if not player:
		return
	if infinite:
		_update_infinite()
	else:
		_replenish(_closest_s(player.global_position))


## --- Closed loop -------------------------------------------------------------

## Chains each element of the level consecutively to compute the placement
## transform of every slot's entry point, starting from the loop origin.
func _build_spine() -> void:
	_slot_count = track_level.count()
	_lap_length = 0.0
	_spine_kind.resize(_slot_count)
	_spine_transform.resize(_slot_count)
	_spine_pt.resize(_slot_count)

	var heading := 0.0
	var origin := Vector3.ZERO

	for i in _slot_count:
		var kind := track_level.element_at(i)
		var seg := _segment_for(kind)
		_spine_transform[i] = Transform3D(_basis_from_heading(heading), origin)
		_spine_kind[i] = kind
		_spine_pt[i] = origin
		origin += _basis_from_heading(heading) * seg.end()
		heading += seg.turn()
		_lap_length += seg.arc_length()


## Maps each pooled slot to a level slot centred on the player's arc-length.
func _replenish(s_p: float) -> void:
	var first_slot := int(floor(s_p / _seg_length))
	var half := pool_size / 2
	for k in pool_size:
		var slot := first_slot + (k - half)
		var L := posmod(slot, _slot_count)
		var node := _pool[k]
		var segment := _segment_for(_spine_kind[L])
		node.global_transform = _spine_transform[L]
		_apply_segment(node, segment)
		segment_placed.emit(L, node, segment)


## --- Infinite ----------------------------------------------------------------

func _init_infinite() -> void:
	_infinite_level = InfiniteTrackLevel.new()
	_infinite_level.straight_min = straight_min
	_infinite_level.straight_max = straight_max
	_infinite_level.turn_min = turn_min
	_infinite_level.turn_max = turn_max
	_infinite_level.setup(infinite_seed)

	_scroll = Node3D.new()
	_scroll.name = "ScrollOrigin"
	add_child(_scroll)

	_create_pool(_scroll)
	_build_window()


## Recomputes the pooled window around the player, advancing the scroll origin
## so the world geometry stays fixed while coordinates stay bounded.
func _update_infinite() -> void:
	var s_rel := _player_local_s()
	var p_slot := int(floor(s_rel / _seg_length))
	var half := pool_size / 2
	if p_slot > half + 5:
		_recenter(_slot_first + (p_slot - half))
	_snap_player()


## Chains `pool_size` elements ahead of `_slot_first` (in the scroll-local
## frame, heading 0 at the window start) and places the pooled segments.
func _build_window() -> void:
	_window_kind.resize(pool_size)
	_window_tf.resize(pool_size)
	_window_pt.resize(pool_size + 1)

	var heading := 0.0
	var local := Vector3.ZERO

	for k in pool_size:
		var e := _infinite_level.element_at(_slot_first + k)
		var seg := _segment_for(e)
		_window_kind[k] = e
		_window_tf[k] = Transform3D(_basis_from_heading(heading), local)
		_window_pt[k] = local
		local += _basis_from_heading(heading) * seg.end()
		heading += seg.turn()
	_window_pt[pool_size] = local

	for k in pool_size:
		var node := _pool[k]
		var segment := _segment_for(_window_kind[k])
		node.transform = _window_tf[k]
		_apply_segment(node, segment)
		segment_placed.emit(_slot_first + k, node, segment)


## Moves the window's base slot so the player stays near the middle, keeping
## the world pose of every slot invariant (no visual pop).
func _recenter(new_first: int) -> void:
	if new_first == _slot_first:
		return
	var delta := new_first - _slot_first
	if delta <= 0 or delta >= pool_size:
		return
	var old_pose := _scroll.global_transform * _window_tf[delta]
	_slot_first = new_first
	_build_window()
	_scroll.global_transform = old_pose


## Returns the player's arc-length measured in the scroll-local frame.
func _player_local_s() -> float:
	return _local_s_for(player.global_position)


## Returns the arc-length of `pos` measured in the scroll-local frame.
func _local_s_for(pos: Vector3) -> float:
	var p_local := _scroll.global_transform.affine_inverse() * pos
	var p := Vector2(p_local.x, p_local.z)
	var best := 0.0
	var best_d2 := INF
	for i in pool_size:
		var a := Vector2(_window_pt[i].x, _window_pt[i].z)
		var b := Vector2(_window_pt[i + 1].x, _window_pt[i + 1].z)
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d2 := (p - (a + ab * t)).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = float(i) * _seg_length + t * _seg_length
	return best


## Returns the track's forward direction (world space) at the nearest point to
## `pos`. Useful for steering helpers or camera following without imposing any
## movement on the player.
func track_forward_at(pos: Vector3) -> Vector3:
	if not infinite:
		var s := _closest_s(pos)
		var i := int(floor(s / _seg_length))
		return -_spine_transform[i].basis.z
	var p_local := _scroll.global_transform.affine_inverse() * pos
	var p := Vector2(p_local.x, p_local.z)
	var best_s := 0.0
	var best_d2 := INF
	for i in pool_size:
		var a := Vector2(_window_pt[i].x, _window_pt[i].z)
		var b := Vector2(_window_pt[i + 1].x, _window_pt[i + 1].z)
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d2 := (p - (a + ab * t)).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best_s = float(i) * _seg_length + t * _seg_length
	var i := int(clampf(floor(best_s / _seg_length), 0, pool_size - 1))
	return _scroll.global_transform.basis * (-_window_tf[i].basis.z)


## Returns the index of the track element whose centreline is closest to `pos`,
## expressed the same way as the `element_index` of `segment_placed` - so a
## listener can ask "which biome is the player in?" without knowing how the track
## is pooled.
func element_index_at(pos: Vector3) -> int:
	if infinite:
		if _scroll == null:
			return 0
		return _slot_first + int(floor(_local_s_for(pos) / _seg_length))
	if _slot_count <= 0:
		return 0
	return posmod(int(floor(_closest_s(pos) / _seg_length)), _slot_count)


## --- Inspection --------------------------------------------------------------
##
## Read-only helpers for debug overlays, tests and tools. None of them affects
## placement; they answer "where is the runner, and what is under them?" in the
## same terms `segment_placed` reports.

## True when the track is endless (procedural, re-centred around the player)
## rather than a closed loop.
func is_endless() -> bool:
	return infinite


## Length of the closed loop in metres, or 0 on an endless track.
func lap_length() -> float:
	return _lap_length


## Arc length of the element at `element_index`, in metres. A turn is measured
## along the arc it sweeps, so elements are not all the same length even though the
## index grid counts every slot as `straight_segment.length`.
func element_length_at(element_index: int) -> float:
	if _straight_segment == null:
		return 0.0
	return _segment_for(_element_kind_at(element_index)).arc_length()


## Which way the element at `element_index` bends: -1 left, +1 right, 0 straight.
func element_direction_at(element_index: int) -> int:
	var kind := _element_kind_at(element_index)
	if kind == TrackLevel.Kind.STRAIGHT:
		return 0
	if infinite:
		return -1 if kind == InfiniteTrackLevel.Kind.TURN_LEFT else 1
	return signi(track_level.turn_direction)


## Distance travelled along the centreline to the point of it closest to `pos`, in
## metres. An endless track counts from the start of the level, so this grows
## without bound; a closed loop counts from the loop origin, so it wraps each lap.
func track_distance_at(pos: Vector3) -> float:
	if infinite:
		if _scroll == null:
			return 0.0
		return float(_slot_first) * _seg_length + _local_s_for(pos)
	if _slot_count <= 0:
		return 0.0
	return _closest_s(pos)


## How far into the element under `pos` the runner is, as a fraction of that
## element: 0 at its entry, approaching 1 at the seam to the next one. The endless
## track indexes elements by `straight_segment.length`, so this is progress through
## the index grid the biomes are chosen on, not an arc-length ratio on a turn.
func element_progress_at(pos: Vector3) -> float:
	if _seg_length <= 0.0:
		return 0.0
	return clampf(fmod(track_distance_at(pos), _seg_length) / _seg_length, 0.0, 1.0)


## Re-places every pooled segment, which re-emits `segment_placed` for the whole
## pool. Lets listeners update decisions they already made (see
## [method BiomeDirector.refresh]); harmless to call while the track runs, because
## re-placing a segment never moves the track.
func refresh_pool() -> void:
	if infinite:
		if _scroll != null:
			_build_window()
		return
	if _pool.is_empty():
		return
	var s := _closest_s(player.global_position) if player != null else 0.0
	_replenish(s)


## Resets the scroll origin (and the player, which rides along) back toward the
## world origin so coordinates never grow, without moving the player relative
## to the track (interpolation reset hides the teleport).
func _snap_player() -> void:
	var s := _scroll.global_position
	if s.length() <= snap_distance:
		return
	var corr := Vector3(-s.x, 0.0, -s.z)
	player.global_position += corr
	_scroll.global_position += corr
	player.reset_physics_interpolation()
	_scroll.reset_physics_interpolation()


## --- Shared pool -------------------------------------------------------------

func _create_pool(parent: Node) -> void:
	for _i in pool_size:
		var node := StaticBody3D.new()
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.visibility_range_end = 500.0
		var cs := CollisionShape3D.new()
		cs.name = "Collision"
		cs.position.y = -straight_segment.height * 0.5
		node.add_child(mi)
		node.add_child(cs)
		parent.add_child(node)
		_pool.append(node)


## Sizes a box collider from the segment mesh's AABB so it fully encloses the
## floor. Y thickness uses the segment height (the mesh is flat); `margin_x` and
## `margin_z` add safety so the rotated turn box never clips the arc corners.
func _collider_size(seg: TrackSegment, margin_x: float, margin_z: float) -> Vector3:
	var aabb := seg.mesh.get_aabb().size
	return Vector3(aabb.x + margin_x, seg.height, aabb.z + margin_z)


## Element kind at `element_index`, in the level's own enum. Both level kinds
## start with STRAIGHT, so the comparison above is shared.
func _element_kind_at(element_index: int) -> int:
	if infinite:
		if _infinite_level == null:
			return TrackLevel.Kind.STRAIGHT
		return _infinite_level.element_at(element_index)
	if track_level == null:
		return TrackLevel.Kind.STRAIGHT
	return track_level.element_at(element_index)


## Returns the TrackSegment an element kind resolves to. In closed-loop mode
## the single `Kind.TURN` is bent according to the level's `turn_direction`;
## in infinite mode the generator emits distinct left/right kinds directly.
func _segment_for(e: int) -> TrackSegment:
	if e == Kind.STRAIGHT or e == InfiniteTrackLevel.Kind.STRAIGHT:
		return _straight_segment
	if infinite:
		return _turn_right_segment if e == InfiniteTrackLevel.Kind.TURN_RIGHT else _turn_segment
	return _turn_right_segment if track_level.turn_direction > 0 else _turn_segment


func _apply_segment(node: StaticBody3D, seg: TrackSegment) -> void:
	var mi := node.get_node("Mesh") as MeshInstance3D
	var cs := node.get_node("Collision") as CollisionShape3D
	mi.mesh = seg.mesh
	mi.scale.x = 1.0 if seg.direction <= 0 else -1.0
	if seg.is_turn():
		cs.shape = _turn_shape
		cs.rotation.y = seg.turn() * 0.5
		cs.position.z = -_turn_shape.size.z * 0.5
	else:
		cs.shape = _straight_shape
		cs.rotation.y = 0.0
		cs.position.z = -_straight_shape.size.z * 0.5


## Returns the arc-length of the closest point on the centreline polyline
## (closed-loop only).
func _closest_s(pos: Vector3) -> float:
	var p := Vector2(pos.x, pos.z)
	var best := 0.0
	var best_d2 := INF
	for i in _slot_count:
		var a := Vector2(_spine_pt[i].x, _spine_pt[i].z)
		var b := Vector2(_spine_pt[(i + 1) % _slot_count].x, _spine_pt[(i + 1) % _slot_count].z)
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d2 := (p - (a + ab * t)).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = float(i) * _seg_length + t * _seg_length
	return best


func _basis_from_heading(heading: float) -> Basis:
	return Basis(
		Vector3(cos(heading), 0.0, sin(heading)),
		Vector3.UP,
		Vector3(-sin(heading), 0.0, cos(heading))
	)
