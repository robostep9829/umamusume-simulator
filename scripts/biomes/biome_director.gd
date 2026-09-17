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
	&"tonemap_exposure",
	&"tonemap_white",
]

## Decoration layers, in the order and with the names of LAYERS.md.
const DECORATION_LAYERS: Array[int] = [
	BiomeProvider.Layer.NEAR,
	BiomeProvider.Layer.MID,
	BiomeProvider.Layer.FAR,
]

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
		push_warning("BiomeDirector (%s): no TrackManager assigned, biomes stay off." % name)
		return
	if playlist == null:
		push_warning("BiomeDirector (%s): no BiomePlaylist assigned, biomes stay off." % name)
		return

	var problems := playlist.validate()
	if not problems.is_empty():
		push_warning("BiomeDirector (%s): %s" % [name, "\n  - ".join(problems)])

	track.segment_placed.connect(_on_segment_placed)


func _physics_process(_delta: float) -> void:
	if not enabled or track == null or playlist == null:
		return
	var player := track.player
	if player == null:
		return
	var position := player.global_position
	_refresh_anchor(position)
	var provider := playlist.provider_at(track.element_index_at(position))
	if provider != _active_provider:
		_set_active_provider(provider)


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


## Short human-readable state, handy for a debug overlay.
func debug_summary() -> String:
	var current := _active_provider.biome_id if _active_provider != null else &"<none>"
	return "biome: %s | %s" % [current, playlist.describe() if playlist != null else "no playlist"]


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
	for layer in DECORATION_LAYERS:
		var host := _layer_host(body, layer)
		_clear(host)
		if provider == null:
			continue
		var descriptor := provider.decoration(layer)
		if descriptor != null and descriptor.is_usable() and not descriptor.is_ring():
			_build_along_track(host, descriptor, segment, element_index, layer)
		provider.decorate_layer(layer, host, element_index, segment)


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
		var scene_instance := scene.instantiate() as Node3D
		if scene_instance == null:
			push_warning("BiomeDirector: a variant of a BiomeLayer is not a Node3D, it was skipped.")
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
	for child in node.get_children():
		_configure_instance(child, descriptor)


# --- Biomes and atmosphere ---------------------------------------------------

func _set_active_provider(provider: BiomeProvider) -> void:
	_active_provider = provider
	# The horizon belongs to the biome: drop the cached layouts and rebuild it
	# around the anchor it already has.
	_horizon_regions.clear()
	_rebuild_horizon()
	_blend_environment(_target_environment(provider))
	biome_changed.emit(provider)


func _target_environment(provider: BiomeProvider) -> Environment:
	if provider != null:
		var override := provider.environment_override()
		if override != null:
			return override
	return _base_environment


## Cross-fades the world environment to `target`. The resource is duplicated
## first: the authored `.tres` is never written to, and the fade always starts
## from whatever the world currently looks like.
func _blend_environment(target: Environment) -> void:
	if world_environment == null or target == null:
		return
	var current := world_environment.environment
	var blended := target.duplicate() as Environment
	if blended == null:
		return
	if _blend_fields.is_empty():
		_blend_fields = _available_blend_fields(blended)

	if _blend_tween != null and _blend_tween.is_valid():
		_blend_tween.kill()

	var from := {}
	for field in _blend_fields:
		from[field] = current.get(field) if current != null else null
	world_environment.environment = blended

	var duration := environment_transition_time
	if duration <= 0.0:
		return
	_blend_tween = create_tween().set_parallel()
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
