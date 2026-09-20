class_name BiomeDirector
extends Node3D

## Applies a [BiomePlaylist] to a [TrackManager]: road skins, scenery layers and
## biome-to-biome atmosphere changes.
##
## [b]Track-side decoration[/b] hangs off the floor bodies [TrackManager] recycles.
## Those bodies are already posed in their segment's local frame (entry point at
## the origin, -Z forward, +X right of the runner), so a [BiomeLayer] is simply
## parented to them: it follows the track for free - curves included, in both
## directions - and is dropped when the segment is recycled. Every placement is
## derived from the segment's element index and the decoration seed, so
## re-building a segment reproduces exactly the same world-space result. That is
## what makes the endless track's window re-centring - which re-hosts every slot
## on another pooled body - invisible instead of a scenery reshuffle.
## A segment is only rebuilt when its biome or its element index changed, so the
## once-per-frame `segment_placed` signal costs a dictionary lookup.
##
## [b]Horizon content[/b] ([constant BiomeLayer.Mode.RING]) is not tied to any
## segment: it lives on one anchor that is placed ahead of the player and is only
## moved - together with its content - once the player has come close to it.
## Distant scenery therefore lags behind very slowly and costs nothing in between,
## which is the "camera-locked or very slow parallax" layer 3 of LAYERS.md.
##
## [b]Atmosphere[/b] is the one thing that must not change at a chunk boundary, so
## the director watches the biome under the player and cross-fades the
## [WorldEnvironment]'s environment over [member environment_transition_time]
## seconds when the player runs into another biome.

## Emitted when the biome under the player changes. Scenery and atmosphere are
## handled by the director itself; this is for UI, audio or the camera rig.
signal biome_changed(provider: BiomeProvider)

## Environment fields the director cross-fades. Fields an [Environment] does not
## have are skipped, so this stays valid across engine changes. `sky` itself
## cannot be blended and is swapped together with the rest of the biome's
## environment.
const BLENDED_ENVIRONMENT_FIELDS: Array[StringName] = [
	&"background_color",
	&"background_energy_multiplier",
	&"ambient_light_color",
	&"ambient_light_sky_contribution",
	&"ambient_light_energy",
	&"fog_light_color",
	&"fog_light_energy",
	&"fog_density",
	&"fog_aerial_perspective",
	&"fog_sky_affect",
	&"fog_height",
	&"fog_height_density",
	&"fog_sun_scatter",
	&"tonemap_exposure",
	&"tonemap_white",
]

## Decoration layers, in the order and with the names of LAYERS.md.
const DECORATION_LAYERS: Array[int] = [
	BiomeProvider.Layer.NEAR,
	BiomeProvider.Layer.MID,
	BiomeProvider.Layer.FAR,
]

## Seconds between two passes of the front-to-back ranking. The buckets are metres wide
## and only the *order* of two neighbours changes as the runner moves, so a handful of
## passes a second is indistinguishable from one per frame for a fraction of the cost.
## See [BiomeDrawOrder].
const RANKING_INTERVAL := 0.1

## Track to dress. When left empty, a [TrackManager] among the director's
## siblings (or its parent) is used, which is the usual scene layout.
@export var track: TrackManager
## Biomes to apply, in running order. Without one the director stays idle.
@export var playlist: BiomePlaylist
## Environment whose atmosphere follows the biome. Optional, but this is what
## implements "the sky changes only on biome transition" of LAYERS.md.
@export var world_environment: WorldEnvironment
## Seed of every decoration layout of the level. 0 means "only the track's own
## seed matters".
@export var decor_seed: int = 0
## Seconds an atmosphere change takes when the player enters another biome.
@export var environment_transition_time: float = 2.5
## Turn the whole biome system off without removing the node.
@export var enabled: bool = true

# body instance id -> {index, provider, segment} of the last build
var _records: Dictionary = {}
var _active_provider: BiomeProvider
var _anchor: Node3D
var _horizon_regions: Dictionary = {}
var _base_environment: Environment
var _blend_fields: Array[StringName] = []
var _blend_tween: Tween
# Set by the fade itself, see blend_progress().
var _blend_progress := 1.0
# What `playlist.validate()` found at startup, and which runtime problems were
# already printed, so a report never repeats itself (see _report_once).
var _problems: PackedStringArray = PackedStringArray()
var _reported: Dictionary = {}

# Draw-order bookkeeping: one material per (source material, priority) so a whole layer
# shares its overridden materials - and therefore its draw call - instead of each
# instance getting a copy, and the seconds since the last front-to-back pass.
var _priority_materials: Dictionary = {}
var _rank_elapsed := 0.0

# Rebuild accounting, for the debug overlay's `build` line and for a test that wants
# to see how much of the pool a window move re-dresses. Accumulated as the placements
# arrive and published on the next physics frame, so the number belongs to one frame:
# a re-centre places the whole pool at once, and what it costs is the sum of it.
var _build_segments: int = 0
var _build_instances: int = 0
var _build_usec: int = 0
var _last_build: Dictionary = {}


func _ready() -> void:
	_anchor = Node3D.new()
	_anchor.name = "HorizonAnchor"
	add_child(_anchor)

	if world_environment != null and world_environment.environment != null:
		# Kept as the target for biomes without an environment override, and so
		# the authored resource is never written to at runtime.
		_base_environment = world_environment.environment.duplicate() as Environment

	if not enabled:
		return
	if track == null:
		track = _find_track()
	if track == null:
		push_error(
			"BiomeDirector (%s): no TrackManager assigned or found beside it, so no biome "
			% name
			+ "is applied. Point `track` at the level's TrackManager."
		)
		return
	if playlist == null:
		push_error(
			"BiomeDirector (%s): no BiomePlaylist assigned, so no biome is applied. "
			% name
			+ "Point `playlist` at one."
		)
		return

	_report_playlist_problems()
	track.segment_placed.connect(_on_segment_placed)
	# A level lists its TrackManager before its BiomeDirector, so the track places
	# its first pool in its own `_ready()` - which runs first - and announces it
	# while nothing is listening. A closed loop re-announces on the next physics
	# frame anyway, but an endless pool is only announced again when its window
	# re-centres, about 26 elements of running away: without this the run opens on
	# a bare track and the overlay's layer counts sit at 0 until then. A level
	# that lists the director first is fine too - this refresh then finds nothing
	# placed, and the track's own first placement arrives through the signal above.
	track.refresh_pool()
	# The dressing above is finished, and it is the most expensive build of the run in
	# a real level - 280 instanced tree scenes here. Publishing it now rather than at the
	# end of the first frame keeps the start-up cost visible in the overlay and stops it
	# being attributed to a frame that did something else.
	_publish_build()


## Problems [method BiomePlaylist.validate] found at startup, empty when the playlist
## is well formed. Kept so a test or a debug view can read what was reported.
func validation_problems() -> PackedStringArray:
	return _problems


## What the director has already complained about: problem key -> true.
func reported_problems() -> Dictionary:
	return _reported


## Reports the playlist's problems as errors, one message each, prefixed by the file
## they came from. An authoring mistake here does not stop the game - it makes the
## world render something other than what was authored, which is otherwise noticed
## hours later and by eye.
func _report_playlist_problems() -> void:
	_problems = playlist.validate()
	if _problems.is_empty():
		return
	var source := playlist.resource_path
	if source.is_empty():
		source = "<playlist built in code>"
	push_error(
		"BiomeDirector (%s): %s has %d problem(s), biomes still run:"
		% [name, source, _problems.size()]
	)
	for problem in _problems:
		push_error("  - %s" % problem)


## Prints `message` once per `key`. Anything that fails per segment - a variant that
## is not a Node3D, a pooled body without its mesh - would otherwise bury the rest of
## the log under a few hundred identical lines, and is no more useful for it.
func _report_once(key: StringName, message: String) -> void:
	if _reported.has(key):
		return
	_reported[key] = true
	push_error(message)


func _physics_process(delta: float) -> void:
	_advance(delta)
	# Published *after* the frame's work, not before it: the overlay draws in `_process`
	# of the same iteration, so a number published at the top of `_physics_process` is
	# the previous frame's - one frame stale exactly when it matters, which is the frame
	# that froze.
	_publish_build()


## One frame of the director's work: follow the player, dress whatever changed, keep
## the atmosphere aimed at the right biome. Split out so the frame's build accounting is
## published whatever this returns.
func _advance(delta: float) -> void:
	if not enabled or track == null or playlist == null:
		return
	var player := track.player
	if player == null:
		_report_once(
			&"no_player",
			"BiomeDirector (%s): the TrackManager has no `player`, so no biome can be "
			% name
			+ "chosen and decoration is not built."
		)
		return
	var position := player.global_position
	_refresh_anchor(position)
	var provider := playlist.provider_at(track.element_index_at(position))
	if provider != _active_provider:
		_set_active_provider(provider)

	# Last, so the frame's new instances are ranked in the pass that follows them
	# rather than waiting for the next one.
	_rank_elapsed += delta
	if _rank_elapsed >= RANKING_INTERVAL:
		_rank_elapsed = 0.0
		_rank_decorations()


## Biome the player is running in, or `null` before the first physics frame.
func active_provider() -> BiomeProvider:
	return _active_provider


## Drops every cached decision and rebuilds the roads, scenery and horizon of the
## pool. Call it after changing a biome's resources at runtime; while editing in
## the editor the track is not running, so biomes are a play-time feature.
func refresh() -> void:
	_records.clear()
	_horizon_regions.clear()
	if _active_provider != null:
		_rebuild_horizon()
	if track != null:
		# Makes the track re-place and re-announce every pooled segment, which is
		# what the rebuild above hangs off.
		track.refresh_pool()


## Short human-readable state, handy for a log line.
func debug_summary() -> String:
	var current := _active_provider.biome_id if _active_provider != null else &"<none>"
	return "biome: %s | %s" % [current, playlist.describe() if playlist != null else "no playlist"]


## Elements until the biome under the player changes, or -1 when the level keeps
## one biome for the whole run (see [method BiomePlaylist.is_single_biome]).
func elements_to_biome_change() -> int:
	if track == null or playlist == null or track.player == null:
		return -1
	if playlist.is_single_biome():
		return -1
	var element := track.element_index_at(track.player.global_position)
	var run := playlist.run_range_at(element)
	return maxi(run.x + run.y - element, 0)


## Metres until the biome under the player changes, or -1.0 when it never does:
## what is left of the current element plus the full length of the ones between.
## Measured along the elements' own arc lengths, so a stretch of turns counts as
## the 104.7 m each of them really is rather than as the index grid's 100 m.
func distance_to_biome_change() -> float:
	var elements := elements_to_biome_change()
	if elements < 0 or track == null or track.player == null:
		return -1.0
	var position := track.player.global_position
	var element := track.element_index_at(position)
	var distance := track.element_length_at(element) * (1.0 - track.element_progress_at(position))
	for step in elements - 1:
		distance += track.element_length_at(element + step + 1)
	return distance


## Everything the debug overlay shows about the biome system, in one dictionary, so
## a UI does not have to know how biomes, layers and the horizon are stored. Safe
## to call before the first physics frame - the biome fields then say "nothing
## yet" - and safe to call without a player, which is what the self-test does.
func debug_stats() -> Dictionary:
	var stats := {
		"biome": &"<none>",
		"biome_name": "",
		"playlist": playlist.describe() if playlist != null else "no playlist",
		"elements": 0,
		"progress": 0.0,
		"run_first": 0,
		"run_elements": 0,
		"run_progress": 0.0,
		"change_elements": -1,
		"change_distance": -1.0,
		"next_biome": &"",
		"upcoming": [] as Array[Dictionary],
		"variant": 0,
		"variants": 1,
		"atmosphere": "",
		"layers": {},
		"horizon_cards": 0,
		"horizon_distance": 0.0,
		"build": _last_build,
		"problems": _problems.size(),
	}
	if _active_provider != null:
		stats["biome"] = _active_provider.biome_id
		stats["biome_name"] = _active_provider.display_name
		stats["variants"] = _active_provider.road_variant_count()
		if _active_provider.atmosphere != null:
			stats["atmosphere"] = _active_provider.atmosphere.resource_path.get_file()
	if track != null and track.player != null and playlist != null:
		var position := track.player.global_position
		var element := track.element_index_at(position)
		stats["elements"] = element
		stats["progress"] = track.element_progress_at(position)
		if _active_provider != null:
			stats["variant"] = _active_provider.road_variant(element)
		if not playlist.is_single_biome():
			_fill_change_stats(stats, element)
	stats["layers"] = _layer_instance_counts()
	stats["horizon_cards"] = _horizon_instance_count()
	stats["horizon_distance"] = _horizon_distance()
	return stats


func _fill_change_stats(stats: Dictionary, element: int) -> void:
	var run := playlist.run_range_at(element)
	stats["run_first"] = run.x
	stats["run_elements"] = run.y
	var walked : float = float(element - run.x) + stats["progress"]
	stats["run_progress"] = clampf(walked / maxf(float(run.y), 1.0), 0.0, 1.0)
	stats["change_elements"] = maxi(run.x + run.y - element, 0)
	stats["change_distance"] = distance_to_biome_change()
	var next_provider := playlist.provider_at(run.x + run.y)
	stats["next_biome"] = next_provider.biome_id if next_provider != null else &"<none>"
	stats["upcoming"] = _upcoming_runs(element)


## The runs that follow the one under `element_index`, for the overlay's "what is
## coming" line. Empty when the playlist never changes biome.
func _upcoming_runs(element_index: int, count: int = 3) -> Array[Dictionary]:
	var runs: Array[Dictionary] = []
	if playlist == null or playlist.is_single_biome():
		return runs
	var cursor := playlist.run_range_at(element_index)
	var next_element := cursor.x + cursor.y
	for _step in count:
		var provider := playlist.provider_at(next_element)
		if provider == null:
			break
		var run := playlist.run_range_at(next_element)
		runs.append({"id": provider.biome_id, "elements": run.y})
		next_element = run.x + run.y
	return runs


## Instances currently built per decoration layer, walking the pool rather than
## trusting a counter: it reports what is really there.
func _layer_instance_counts() -> Dictionary:
	var counts := {}
	for layer in DECORATION_LAYERS:
		# `Layer.keys()` is an untyped `Array`, so the element is a `Variant` and a
		# `:=` here would be refused by the analyzer; the cast names the type.
		var band := String(BiomeProvider.Layer.keys()[layer])
		var name := band.to_lower()
		# A band's instances live in one of two places: an along-track layer parents
		# them to the segment bodies, a `RING` one to the horizon anchor. Both are
		# counted, so a band that is a ring reads its card count instead of a
		# permanent 0 - the overlay's `layers` line is only worth reading if it says
		# what is actually in the world.
		var total := _count_instances(track, "BiomeLayer%s" % band)
		total += _count_instances(_anchor, "Horizon%s" % band)
		counts[name] = total
	return counts


func _count_instances(root: Node, container_name: String) -> int:
	if root == null:
		return 0
	var total := 0
	for child in root.get_children():
		if child.name == container_name:
			total += child.get_child_count()
		else:
			total += _count_instances(child, container_name)
	return total


func _horizon_instance_count() -> int:
	if _anchor == null:
		return 0
	var total := 0
	for container in _anchor.get_children():
		total += container.get_child_count()
	return total


## How far the horizon anchor currently sits from the runner: it rides along, so
## this is the ring's lead, and a ring that drifts away means the anchor is stuck.
func _horizon_distance() -> float:
	if _anchor == null or track == null or track.player == null:
		return 0.0
	return _anchor.global_position.distance_to(track.player.global_position)


# --- Segment side ------------------------------------------------------------

## Called for every floor body the track places. Applies the road skin of the
## owning biome and rebuilds the decoration of the segment when the body now
## shows something else than before.
func _on_segment_placed(element_index: int, body: StaticBody3D, segment: TrackSegment) -> void:
	if not enabled or playlist == null or body == null or segment == null:
		return
	var provider := playlist.provider_at(element_index)
	_skin_road(body, segment, provider, element_index)

	var key := body.get_instance_id()
	var record: Dictionary = _records.get(key, {})
	var unchanged: bool = record.get("index", -1) == element_index
	unchanged = unchanged and record.get("provider") == provider
	unchanged = unchanged and record.get("segment") == segment
	if unchanged:
		return
	_rebuild_decoration(body, segment, provider, element_index)
	_records[key] = {"index": element_index, "provider": provider, "segment": segment}


## Road skin: material and, if the biome replaces it, the mesh itself. Runs on
## every placement because [TrackManager] re-applies the authored mesh each time,
## which is also what makes "return null to keep the authored skin" work.
func _skin_road(
	body: Node3D, segment: TrackSegment, provider: BiomeProvider, element_index: int
) -> void:
	var mesh_instance := body.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_instance == null:
		# TrackManager's pool names the road mesh "Mesh"; without it there is nothing
		# to paint, and every one of the pool's bodies would fail the same way.
		_report_once(
			&"no_mesh_child",
			"BiomeDirector (%s): a pooled body of the track has no `Mesh` child, so its "
			% name
			+ "road skin was not applied. Check TrackManager's pool."
		)
		return
	if provider == null:
		mesh_instance.material_override = null
		return
	var variant := provider.road_variant(element_index)
	var road_mesh := provider.road_mesh(segment, variant)
	if road_mesh != null:
		mesh_instance.mesh = road_mesh
	mesh_instance.material_override = provider.road_material(segment, variant)


func _rebuild_decoration(
	body: Node3D, segment: TrackSegment, provider: BiomeProvider, element_index: int
) -> void:
	var started := Time.get_ticks_usec()
	var instances := 0
	for layer in DECORATION_LAYERS:
		var host := _layer_host(body, layer)
		_clear(host)
		if provider == null:
			continue
		var descriptor := provider.decoration(layer)
		if descriptor != null and descriptor.is_usable() and not descriptor.is_ring():
			_build_along_track(host, descriptor, segment, element_index, layer)
		provider.decorate_layer(layer, host, element_index, segment)
		instances += host.get_child_count()
	_build_segments += 1
	_build_instances += instances
	_build_usec += Time.get_ticks_usec() - started


## Moves the frame's rebuild accounting into [member _last_build] and clears it, so
## the overlay reads the cost of a whole frame - a re-centre places every body in
## one - rather than a running total nobody can attribute to anything.
##
## Called wherever a build finishes - the end of every physics frame, and the end of
## `_ready()` after the level's first dressing - so the readout always describes the most
## recent thing that was built, and while running that is the frame that just ran. It
## keeps the last frame that built something: a frame with nothing to do leaves the
## readout alone instead of flickering it to zero, which is what makes the number worth
## watching while the pool turns over.
func _publish_build() -> void:
	if _build_segments > 0:
		_last_build = {
			"segments": _build_segments,
			"instances": _build_instances,
			"usec": _build_usec,
		}
		_build_segments = 0
		_build_instances = 0
		_build_usec = 0


## What the last frame that rebuilt anything cost: `segments` re-dressed,
## `instances` decoration nodes built for them, `usec` spent doing it. Empty before
## the first frame that rebuilt something.
##
## A window re-centre should report a handful of segments - only the elements that
## entered it - and the same for a lap of a closed loop. A number near the pool size
## means every body changed element, which is 280 instanced tree scenes in the demo
## level and a visible freeze.
func last_build() -> Dictionary:
	return _last_build


# --- Horizon side ------------------------------------------------------------

## Keeps the horizon anchor under the player. A ring layer is far scenery - its
## cards sit in a circle around the anchor - so riding along with the runner means
## the horizon surrounds them in every direction instead of piling up in front of
## them, and no card can ever be outrun. Only the direction the runner faces
## changes which part of it they see, which is what a real horizon does.
func _refresh_anchor(position: Vector3) -> void:
	if _active_provider == null or track == null:
		return
	if _widest_ring_radius() <= 0.0:
		# Nothing to keep around the runner: a biome without a horizon must not
		# rebuild an empty anchor every frame.
		return
	_anchor.global_position = Vector3(position.x, 0.0, position.z)
	if _ring_regions_changed():
		_rebuild_horizon()


## True once any ring layer has moved on to another region, which is the only time
## the horizon's layout changes: a card kilometres away that re-randomised every
## frame would make the distance crawl, and one that never did would show the same
## hills for the whole level. A ring stays put for `host_every` elements, exactly
## like the along-track layers.
func _ring_regions_changed() -> bool:
	var element_index := track.element_index_at(_anchor.global_position)
	var changed := false
	for layer in DECORATION_LAYERS:
		var descriptor := _active_provider.decoration(layer)
		if descriptor == null or not descriptor.is_usable() or not descriptor.is_ring():
			changed = _horizon_regions.erase(layer) or changed
			continue
		var region := element_index / maxi(descriptor.host_every, 1)
		if not _horizon_regions.has(layer) or int(_horizon_regions[layer]) != region:
			_horizon_regions[layer] = region
			changed = true
	return changed


## Radius of the widest ring of the active biome, or 0 when it has none: what the
## anchor has to stay clear of.
func _widest_ring_radius() -> float:
	var radius := -1.0
	if _active_provider != null:
		for layer in DECORATION_LAYERS:
			var descriptor := _active_provider.decoration(layer)
			if descriptor != null and descriptor.is_usable() and descriptor.is_ring():
				radius = descriptor.distance_max if radius < 0.0 else maxf(radius, descriptor.distance_max)
	return maxf(radius, 0.0)


func _rebuild_horizon() -> void:
	for layer in DECORATION_LAYERS:
		var host := _horizon_host(layer)
		_clear(host)
		if _active_provider == null or track == null:
			continue
		var descriptor := _active_provider.decoration(layer)
		if descriptor == null or not descriptor.is_usable() or not descriptor.is_ring():
			continue
		_build_ring(host, descriptor, track.element_index_at(_anchor.global_position), layer)


# --- Builders ----------------------------------------------------------------

## Spreads instances along the hosted segment's arc, beside the track.
func _build_along_track(
	host: Node3D, descriptor: BiomeLayer, segment: TrackSegment, element_index: int, layer: int
) -> void:
	if descriptor.host_every > 1 and posmod(element_index, descriptor.host_every) != 0:
		return
	var sides := _sides_of(descriptor.side)
	var per_side := maxi(descriptor.count, 1)
	var total := sides.size() * per_side
	if total <= 0:
		return

	var span := maxf(1.0 - 2.0 * descriptor.edge_margin, 0.0)
	var share := BiomePlacement.length(segment) * span / float(per_side)
	var multimesh_instance: MultiMeshInstance3D = null
	var slot := 0

	for s in sides:
		for i in per_side:
			var rng := BiomePlacement.instance_rng(decor_seed + descriptor.seed, layer, element_index, slot)
			slot += 1

			var jitter := (rng.randf() - 0.5) * descriptor.along_scatter
			var share_t := (float(i) + 0.5 + jitter) / float(per_side)
			var t := descriptor.edge_margin + span * share_t
			var distance := rng.randf_range(descriptor.distance_min, descriptor.distance_max)
			distance += rng.randf_range(-1.0, 1.0) * descriptor.lateral_scatter
			var lift := descriptor.lift + rng.randf_range(-1.0, 1.0) * descriptor.lift_scatter
			var yaw := -s * PI * 0.5 if descriptor.face_track else 0.0
			yaw += deg_to_rad(rng.randf_range(-1.0, 1.0) * descriptor.yaw_scatter)
			var scale := rng.randf_range(descriptor.scale_min, descriptor.scale_max)
			var placement := BiomePlacement.local_transform(
				segment, t, s * distance, lift, yaw, Vector3.ONE * scale
			)

			if descriptor.multimesh and not descriptor.meshes.is_empty():
				if multimesh_instance == null:
					multimesh_instance = _make_multimesh(host, descriptor, total)
				var stretched := _fitted_transform(placement, descriptor.meshes[0], descriptor, share)
				multimesh_instance.multimesh.set_instance_transform(slot - 1, stretched)
			else:
				_spawn(host, descriptor, placement, rng, share)


## Spreads instances on a ring around the horizon anchor, all facing its middle.
##
## The ring is seeded per `host_every` elements instead of per element, so a
## horizon can be told to change rarely (`host_every = 8`) instead of on every
## re-snap (`host_every = 1`).
##
## Orientation follows [method BiomePlacement.basis_from_heading], the convention
## of the track itself: the instance's -Z (Godot's forward) points at the middle
## of the ring. A card whose visible side is its +Z - a plain [QuadMesh] - needs
## `flip_faces` or a billboard/double-sided material.
func _build_ring(host: Node3D, descriptor: BiomeLayer, element_index: int, layer: int) -> void:
	var total := maxi(descriptor.count, 1)
	var region := int(floor(float(element_index) / float(maxi(descriptor.host_every, 1))))
	var slot := 0
	for i in total:
		var rng := BiomePlacement.instance_rng(decor_seed + descriptor.seed, layer, region, slot)
		slot += 1
		# The slot jitter is kept small on purpose: a ring that clumps its cards
		# leaves holes of empty sky between them, and a few rectangles with gaps in
		# between read as floating cards rather than as a horizon.
		var angle := TAU * (float(i) + rng.randf_range(-0.15, 0.15)) / float(total)
		var distance := rng.randf_range(descriptor.distance_min, descriptor.distance_max)
		var lift := descriptor.lift + rng.randf_range(-1.0, 1.0) * descriptor.lift_scatter
		var position := Vector3(cos(angle), 0.0, sin(angle)) * distance + Vector3(0.0, lift, 0.0)
		var yaw := angle - PI * 0.5 + deg_to_rad(rng.randf_range(-1.0, 1.0) * descriptor.yaw_scatter)
		var scale := rng.randf_range(descriptor.scale_min, descriptor.scale_max)
		var basis := BiomePlacement.scaled(BiomePlacement.basis_from_heading(yaw), Vector3.ONE * scale)
		_spawn(host, descriptor, Transform3D(basis, position), rng, 0.0)


## Instances one decoration. Scenes win over meshes, so a biome can be moved to
## real props without touching the code.
func _spawn(
	host: Node3D, descriptor: BiomeLayer, placement: Transform3D, rng: RandomNumberGenerator,
	share: float
) -> Node3D:
	if not descriptor.variants.is_empty():
		var scene := descriptor.variants[rng.randi_range(0, descriptor.variants.size() - 1)]
		if scene == null:
			_report_once(
				StringName("empty_variant:%s" % descriptor.resource_path),
				"BiomeDirector: `%s` has an empty entry in `variants`, so that instance "
				% _path_of(descriptor)
				+ "was skipped."
			)
			return null
		var scene_instance := scene.instantiate() as Node3D
		if scene_instance == null:
			# Reported once per scene: a prop that cannot be posed would otherwise fail
			# on every element it is drawn on.
			_report_once(
				StringName("variant_root:%s" % scene.resource_path),
				"BiomeDirector: `%s` is not a Node3D, so it cannot be placed; it will be "
				% _path_of(scene)
				+ "skipped wherever a layer lists it."
			)
			return null
		scene_instance.transform = placement
		_configure_instance(scene_instance, descriptor)
		host.add_child(scene_instance)
		return scene_instance

	if descriptor.meshes.is_empty():
		return null
	var mesh: Mesh = descriptor.meshes[0]
	if not descriptor.multimesh:
		mesh = descriptor.meshes[rng.randi_range(0, descriptor.meshes.size() - 1)]
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	if descriptor.mesh_material != null:
		mesh_instance.material_override = descriptor.mesh_material
	mesh_instance.transform = _fitted_transform(placement, mesh, descriptor, share)
	_configure_instance(mesh_instance, descriptor)
	host.add_child(mesh_instance)
	return mesh_instance


func _make_multimesh(host: Node3D, descriptor: BiomeLayer, count: int) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = descriptor.meshes[0]
	multimesh.instance_count = count
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	if descriptor.mesh_material != null:
		instance.material_override = descriptor.mesh_material
	_configure_instance(instance, descriptor)
	host.add_child(instance)
	return instance


## Turns one placement into a strip that tiles across its share of the segment:
## the mesh's longest horizontal side is rotated onto the track and stretched to
## `share` metres, and the mesh is centred on the placement along the ground, so
## the author does not have to know the segment length nor where the mesh sits
## relative to its origin (the vertical placement is left alone, so props keep the
## ground they were authored on).
func _fitted_transform(
	placement: Transform3D, mesh: Mesh, descriptor: BiomeLayer, share: float
) -> Transform3D:
	if not descriptor.fit_to_segment or share <= 0.0 or mesh == null:
		return placement
	var size := mesh.get_aabb().size
	var along_x := size.x >= size.z
	var extent := maxf(size.x if along_x else size.z, 0.001)
	var factor := share / extent
	var basis := placement.basis
	if along_x:
		basis = basis * Basis(Vector3.UP, -PI * 0.5)
		basis = BiomePlacement.scaled(basis, Vector3(factor, 1.0, 1.0))
	else:
		basis = BiomePlacement.scaled(basis, Vector3(1.0, 1.0, factor))
	# Ground-plane correction only: a mesh authored off-centre still ends up
	# centred on its share, without changing the height it was authored at.
	var offset := basis * mesh.get_aabb().get_center()
	offset.y = 0.0
	return Transform3D(basis, placement.origin - offset)


func _configure_instance(node: Node, descriptor: BiomeLayer) -> void:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		if descriptor.visible_range > 0.0:
			geometry.visibility_range_end = descriptor.visible_range
		if not descriptor.cast_shadow:
			geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Origin-based depth, so the distance the engine sorts by is the distance
		# [BiomeDrawOrder] can compute: a tree's bounds centre sits in its canopy, and
		# a horizon card's is metres above the ground it was authored around.
		geometry.sorting_use_aabb_center = false
		if descriptor.override_render_priority:
			_apply_render_priority(geometry, descriptor.render_priority)
	for child in node.get_children():
		_configure_instance(child, descriptor)


# --- Draw order --------------------------------------------------------------
#
# The order the opaque pass is submitted in is decided by one packed key, and distance
# is the last field of it - see [BiomeDrawOrder] for the key itself. Two things follow
# from that, and they are the two halves of this section:
#
# * `render_priority` orders *groups*. It is the first field of the key, so it is the
#   only way a project can say "the road, then the trunks, then the canopies", and it
#   has to come from somewhere other than the material: a layer's props carry their
#   material inside their scenes and meshes, and those assets are shared with other
#   levels, so a [BiomeLayer] declares the priority and the director applies it to a
#   copy of the material.
# * the sixteen distance buckets order the instances *inside* one group, which is what
#   `_rank_decorations` hands out. Without it a layer's instances tie on every field
#   and come out in whatever order the engine's sort left them in.


## Forces `priority` onto the material `geometry` draws with, through a copy of it that
## every instance of the layer shares.
##
## A copy rather than the material itself: the layer's materials are shared - the leaf
## material lives inside `leaf_mesh.tres` and `uma_island` draws it too - so editing one
## would reorder somebody else's level. One copy per (material, priority) and not one per
## instance, so the instances still batch.
func _apply_render_priority(geometry: GeometryInstance3D, priority: int) -> void:
	var material := _effective_material(geometry)
	if material == null:
		return
	var key := "%d:%d" % [material.get_instance_id(), priority]
	var clone: Material = _priority_materials.get(key)
	if clone == null:
		clone = material.duplicate() as Material
		clone.render_priority = priority
		_priority_materials[key] = clone
	geometry.material_override = clone


## The material `geometry` ends up drawing with: its own override if it has one, else the
## first surface material of the mesh it draws. There is no engine call for this on a
## [MultiMeshInstance3D], and a scene's props carry their material in the mesh - the
## tree's leaves are a [ShaderMaterial] inside `leaf_mesh.tres` - so both cases are read
## here by hand.
func _effective_material(geometry: GeometryInstance3D) -> Material:
	if geometry.material_override != null:
		return geometry.material_override
	var mesh: Mesh = null
	if geometry is MeshInstance3D:
		mesh = (geometry as MeshInstance3D).mesh
	elif geometry is MultiMeshInstance3D:
		var holder := geometry as MultiMeshInstance3D
		if holder.multimesh != null:
			mesh = holder.multimesh.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	return mesh.surface_get_material(0)


## The camera the frame will be drawn with, or `null` in a run without one - a headless
## test, for instance, where the ranking has nothing to rank by.
func _active_camera() -> Camera3D:
	var viewport := get_viewport()
	if viewport == null:
		return null
	return viewport.get_camera_3d()


## Gives every instance of every band a place in the engine's sixteen distance buckets,
## nearest first: see [BiomeDrawOrder] for what that can and cannot order.
##
## One pass per layer, and only over the bodies that are near enough to have a drawn
## instance at all, so the walk is a few dozen nodes rather than the whole pool.
func _rank_decorations() -> void:
	var camera := _active_camera()
	if camera == null:
		return
	var origin := camera.global_position
	var far := camera.get_far()
	var near := camera.get_near()
	# The far plane cuts the world at `far` and a band's own `visible_range` can only
	# pull that in, so nothing beyond this can be drawn. One bucket of slack, so a node
	# sitting exactly on the boundary is still ranked.
	var limit := far + BiomeDrawOrder.bucket_size(far, near)
	for layer in DECORATION_LAYERS:
		# `Layer.keys()` is an untyped `Array`, so the element is a `Variant` and a `:=`
		# here would be refused by the analyzer; the cast names the type.
		var band := String(BiomeProvider.Layer.keys()[layer])
		var nodes: Array[GeometryInstance3D] = []
		_collect_instances(track, "BiomeLayer%s" % band, origin, limit, nodes)
		_collect_instances(_anchor, "Horizon%s" % band, origin, limit, nodes)
		BiomeDrawOrder.rank(nodes, origin, far, near)


## Every [GeometryInstance3D] under a `container_name` node of `root`, skipping whole
## subtrees further than `limit` from `origin`.
##
## The containers are children of the segment bodies (or of the horizon anchor), and a
## body is one node, so the distance check prunes a reused body - and everything it
## carries - before the walk descends into it.
func _collect_instances(
	root: Node, container_name: String, origin: Vector3, limit: float, into: Array[GeometryInstance3D]
) -> void:
	if root == null:
		return
	if root.name == container_name:
		_collect_geometry(root, into)
		return
	for child in root.get_children():
		if not (child is Node3D):
			continue
		var holder := child as Node3D
		if origin.distance_to(holder.global_position) > limit:
			continue
		_collect_instances(child, container_name, origin, limit, into)


func _collect_geometry(node: Node, into: Array[GeometryInstance3D]) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			into.append(child as GeometryInstance3D)
		_collect_geometry(child, into)


## Reports a horizon ring parked beyond the camera's far plane, where nothing will ever
## draw it.
##
## The camera's far plane is the one limit a [BiomeLayer] cannot check for itself - it is
## a property of the level's camera, not of the layer - so the layer's own validation
## cannot see it, and a ring that is silently never drawn looks exactly like a ring whose
## biome was never reached.
func _report_ring_reach(provider: BiomeProvider) -> void:
	var camera := _active_camera()
	if camera == null:
		return
	var far := camera.get_far()
	for layer in DECORATION_LAYERS:
		var descriptor := provider.decoration(layer)
		if descriptor == null or not descriptor.is_usable() or not descriptor.is_ring():
			continue
		if descriptor.distance_max <= far:
			continue
		_report_once(
			StringName("ring_beyond_far:%s" % _path_of(descriptor)),
			"BiomeDirector: the horizon of `%s` sits at %s m, past the camera's far "
			% [_path_of(descriptor), String.num(descriptor.distance_max, 0)]
			+ "plane (%s m), so it is never drawn. Bring the ring inside the far plane "
			% String.num(far, 0)
			+ "or raise `Camera3D.far`."
		)


# --- Biomes and atmosphere ---------------------------------------------------
#
# A biome's `atmosphere` is a whole [Environment], not a patch on the level's:
# while a biome with one is active, the [WorldEnvironment] renders *that* file, so
# a fog or sky setting left in the level's environment only survives until the
# first biome is applied. Author the fog where the biome reads it, and give a
# provider no `atmosphere` to keep the level's own. The switch is cross-faded, but
# only for the numeric fields below - `sky`, `fog_enabled` and the rest are swapped
# together with the resource, because a sky cannot be interpolated.

func _set_active_provider(provider: BiomeProvider) -> void:
	# The first biome of a run is applied as it is, without a fade: fading in from
	# the level's own environment would show *that* look - possibly a different time
	# of day, or much denser fog - for the length of the fade at the start of every
	# run, which is not a biome transition.
	var first := _active_provider == null
	_active_provider = provider
	# The horizon belongs to the biome: drop the cached layouts and rebuild it
	# around the anchor it already has.
	_horizon_regions.clear()
	_rebuild_horizon()
	_blend_environment(_target_environment(provider), first)
	if provider != null:
		# Checked on every change, not only at startup: a biome is data, and the ring
		# of a biome the run has not reached yet has not been looked at by anything.
		_report_ring_reach(provider)
	biome_changed.emit(provider)


func _target_environment(provider: BiomeProvider) -> Environment:
	if provider != null:
		var override := provider.environment_override()
		if override != null:
			return override
	return _base_environment


## The [Environment] the world is rendering right now, or `null` when the level
## has no [WorldEnvironment]. While a transition runs this is the half-faded
## duplicate, which is what makes it useful to a debug readout: it shows what the
## scene looks like, not what the biome asked for.
func live_environment() -> Environment:
	return world_environment.environment if world_environment != null else null


## How far the running atmosphere transition has come: 0 when it starts, 1 when it
## is done, and 1 whenever nothing is fading. Read by debug views.
##
## The number is written by the fade itself - a method tweener runs beside the field
## tweeners and stores the fraction - instead of being read back out of the [Tween].
## A [Tween] has no "how far along am I" call: `get_total_elapsed_time()` counts the
## time since it started but nothing remembers the duration it was started with, and
## a fade stepped by hand (`custom_step()`, which the self-test uses) would have to be
## reflected here separately. Letting the tween write it keeps the two in step by
## construction.
func blend_progress() -> float:
	return _blend_progress


## Cross-fades the world environment to `target`. The resource is duplicated
## first: the authored `.tres` is never written to, and the fade always starts
## from whatever the world currently looks like.
func _blend_environment(target: Environment, instant: bool = false) -> void:
	if world_environment == null:
		# A biome is carrying an atmosphere and nothing in the level can render it.
		_report_once(
			&"no_world_environment",
			"BiomeDirector (%s): a biome carries an atmosphere, but `world_environment` "
			% name
			+ "is not set, so no sky, fog or light of a biome is ever shown."
		)
		return
	if target == null:
		_report_once(
			&"no_environment",
			"BiomeDirector (%s): neither the biome nor the level's WorldEnvironment has "
			% name
			+ "an environment, so the atmosphere stays whatever it was."
		)
		return
	var current := world_environment.environment
	var blended := target.duplicate() as Environment
	if blended == null:
		return
	if _blend_fields.is_empty():
		_blend_fields = _available_blend_fields(blended)

	if _blend_tween != null and _blend_tween.is_valid():
		_blend_tween.kill()
	_blend_tween = null

	var from := {}
	for field in _blend_fields:
		from[field] = current.get(field) if current != null else null
	world_environment.environment = blended

	var duration := 0.0 if instant else environment_transition_time
	_blend_progress = 1.0 if duration <= 0.0 else 0.0
	if duration <= 0.0:
		return
	_blend_tween = create_tween().set_parallel()
	_blend_tween.tween_method(_set_blend_progress, 0.0, 1.0, duration)
	for field in _blend_fields:
		var to_value: Variant = blended.get(field)
		var from_value: Variant = from.get(field)
		if from_value == null or typeof(from_value) != typeof(to_value):
			continue
		if typeof(to_value) == TYPE_COLOR:
			var colour := _set_environment_color.bind(blended, field)
			_blend_tween.tween_method(colour, from_value, to_value, duration)
		elif typeof(to_value) == TYPE_FLOAT:
			var number := _set_environment_float.bind(blended, field)
			_blend_tween.tween_method(number, float(from_value), float(to_value), duration)


func _available_blend_fields(environment: Environment) -> Array[StringName]:
	var existing := {}
	for info in environment.get_property_list():
		existing[StringName(info["name"])] = true
	var fields: Array[StringName] = []
	for field in BLENDED_ENVIRONMENT_FIELDS:
		if existing.has(field):
			fields.append(field)
	return fields


## Stores how far the fade is, for [method blend_progress]. Called by the tween.
func _set_blend_progress(value: float) -> void:
	_blend_progress = value


func _set_environment_color(value: Color, environment: Environment, field: StringName) -> void:
	environment.set(field, value)


func _set_environment_float(value: float, environment: Environment, field: StringName) -> void:
	environment.set(field, value)


# --- Helpers -----------------------------------------------------------------

func _find_track() -> TrackManager:
	var parent := get_parent()
	if parent is TrackManager:
		return parent
	if parent != null:
		for sibling in parent.get_children():
			if sibling is TrackManager:
				return sibling
	return null


## Short name of a resource for a console message: its path, or its class when it was
## built in code and has none.
func _path_of(resource: Resource) -> String:
	if resource == null:
		return "<empty>"
	return resource.resource_path if not resource.resource_path.is_empty() else "<inline resource>"


func _layer_host(body: Node3D, layer: int) -> Node3D:
	return _container(body, "BiomeLayer%s" % BiomeProvider.Layer.keys()[layer])


func _horizon_host(layer: int) -> Node3D:
	return _container(_anchor, "Horizon%s" % BiomeProvider.Layer.keys()[layer])


func _container(parent: Node3D, container_name: String) -> Node3D:
	var container := parent.get_node_or_null(container_name) as Node3D
	if container == null:
		container = Node3D.new()
		container.name = container_name
		parent.add_child(container)
	return container


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


func _sides_of(side: BiomeLayer.Side) -> Array[int]:
	match side:
		BiomeLayer.Side.LEFT:
			return [-1]
		BiomeLayer.Side.RIGHT:
			return [1]
		_:
			return [-1, 1]
