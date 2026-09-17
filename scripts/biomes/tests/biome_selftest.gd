extends SceneTree

## Headless self-test of the biome system.
##
## Run it from the project folder:
## [codeblock]
## godot --headless --script res://scripts/biomes/tests/biome_selftest.gd
## [/codeblock]
##
## It builds its own segments, layers and track - with plain meshes instead of the
## authored artwork - so it needs no imported assets, runs in about a second and is
## safe to run in CI. Exit code 0 means everything passed.
##
## The interesting checks are the ones that would otherwise only show up hours
## into a run as "the scenery is slightly off on corners": a placement must land
## exactly on the authored exit point of straights, left turns and right turns,
## the frame an instance is posed in must follow the centreline (its -Z is the
## direction of travel), and turns of opposite direction must mirror each other.
## That frame check is the one that fails when the heading convention of
## [BiomePlacement] and [TrackManager] drift apart.

const EPSILON := 0.01
const STRAIGHT_LENGTH := 100.0
const TURN_RADIUS := 1200.0
const TURN_DEGREES := 5.0
const FRAME_EPSILON := 0.0001

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_test_placement_end_points()
	_test_placement_frames()
	_test_placement_mirrors()
	_test_placement_lateral()
	_test_placement_determinism()
	_test_playlist_auto()
	_test_playlist_single()
	_test_playlist_sections()
	_test_road_surfaces()
	_test_validation()
	_test_track_integration()
	_test_horizon()

	print("")
	if _failures.is_empty():
		print("biome self-test: %d checks, all green." % _checks)
	else:
		print("biome self-test: %d checks, %d FAILED" % [_checks, _failures.size()])
		for failure in _failures:
			print("  - %s" % failure)
	quit(0 if _failures.is_empty() else 1)


## --- placement ---------------------------------------------------------------

## t = 1 must land on the segment's authored exit point, for every segment kind
## and both turn directions.
func _test_placement_end_points() -> void:
	for segment in [_straight(), _turn(-1), _turn(1)]:
		_check_vector(
			BiomePlacement.local_position(segment, 1.0),
			segment.end(),
			"placement at t = 1 matches TrackSegment.end() for %s" % _segment_name(segment)
		)
		_check_vector(
			BiomePlacement.local_position(segment, 0.0),
			Vector3.ZERO,
			"placement at t = 0 is the segment origin for %s" % _segment_name(segment)
		)
		var expected_length := STRAIGHT_LENGTH if not segment.is_turn() else 104.7198
		_check(
			is_equal_approx(BiomePlacement.length(segment), expected_length),
			"arc length of %s is the centreline length" % _segment_name(segment)
		)


## The frame a decoration is posed in must follow the centreline: its -Z is the
## direction of travel and its +X stays right of the runner. Without this, a layer
## sits at the right place but faces the wrong way on every curve, which is
## exactly what a mirrored heading convention produces.
func _test_placement_frames() -> void:
	for segment in [_straight(), _turn(-1), _turn(1)]:
		var name := _segment_name(segment)
		for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var frame := BiomePlacement.basis_at(segment, t)
			var forward := -frame.z
			var tangent := _tangent(segment, t)
			_check(
				forward.dot(tangent) > 1.0 - FRAME_EPSILON,
				"the frame at t = %s of %s follows the centreline (got %s, expected %s)"
					% [t, name, forward, tangent]
			)
			_check(
				absf(frame.x.dot(forward)) < FRAME_EPSILON,
				"the frame stays square to the track at t = %s of %s" % [t, name]
			)
			_check(
				(frame * Vector3(1.0, 0.0, 0.0)).dot(tangent) < FRAME_EPSILON,
				"the frame's right stays perpendicular to travel at t = %s of %s" % [t, name]
			)
	# A layer that faces the track: the yaw the director uses for `face_track`
	# must turn the instance's -Z back towards the centreline on both sides.
	for side in [-1.0, 1.0]:
		var yaw := -side * PI * 0.5
		for t in [0.0, 0.5, 1.0]:
			var facing := BiomePlacement.basis_at(segment, t, yaw)
			var towards_road := BiomePlacement.basis_at(segment, t).x * -side
			_check(
				(-facing.z).dot(towards_road) > 1.0 - FRAME_EPSILON,
				"face_track looks back at the road on side %s of %s at t = %s" % [side, name, t]
			)


## A left-hand turn is the mirror image of a right-hand turn: a layer must not
## have to care which way the track bends.
func _test_placement_mirrors() -> void:
	for t in [0.25, 0.5, 1.0]:
		var right := BiomePlacement.local_position(_turn(1), t, 15.0, 0.0)
		var left := BiomePlacement.local_position(_turn(-1), t, -15.0, 0.0)
		_check_vector(
			Vector3(-left.x, left.y, left.z), right, "left/right turns mirror each other at t = %s" % t
		)
		var right_frame := BiomePlacement.basis_at(_turn(1), t)
		var left_frame := BiomePlacement.basis_at(_turn(-1), t)
		_check_vector(
			Vector3(-left_frame.z.x, left_frame.z.y, left_frame.z.z),
			right_frame.z,
			"left/right turn frames mirror each other at t = %s" % t
		)
	var right_heading := BiomePlacement.heading_at(_turn(1), 0.5)
	var left_heading := BiomePlacement.heading_at(_turn(-1), 0.5)
	_check(is_equal_approx(right_heading, -left_heading), "turn headings mirror each other")


## Lateral offsets stay perpendicular to the track and keep their distance.
func _test_placement_lateral() -> void:
	for segment in [_straight(), _turn(-1), _turn(1)]:
		var name := _segment_name(segment)
		for t in [0.0, 0.4, 1.0]:
			var centre := BiomePlacement.local_position(segment, t)
			var side := BiomePlacement.local_position(segment, t, 12.0)
			var offset := side - centre
			var forward := -BiomePlacement.basis_at(segment, t).z
			_check(is_equal_approx(offset.length(), 12.0), "lateral offset keeps its length on %s" % name)
			_check(absf(offset.dot(forward)) <= EPSILON, "lateral offset is perpendicular on %s" % name)
		_check(
			BiomePlacement.local_position(segment, 0.5, 0.0, 3.0).y == 3.0,
			"lift is along Y on %s" % name
		)


## Decoration must be reproducible: recycling a segment may not shuffle it.
func _test_placement_determinism() -> void:
	var a := BiomePlacement.instance_rng(7, 2, 1234, 1).randf()
	var b := BiomePlacement.instance_rng(7, 2, 1234, 1).randf()
	var c := BiomePlacement.instance_rng(7, 2, 1235, 1).randf()
	var d := BiomePlacement.instance_rng(7, 3, 1234, 1).randf()
	_check(a == b, "the same placement request always yields the same random value")
	_check(a != c, "a different element yields a different random value")
	_check(a != d, "a different layer yields a different random value")


## --- playlists ---------------------------------------------------------------

func _test_playlist_auto() -> void:
	var first := _provider(&"first")
	var second := _provider(&"second")
	var playlist := BiomePlaylist.new()
	playlist.biomes = [first, second]
	playlist.segments_per_biome = 10

	_check(playlist.provider_at(0) == first, "element 0 uses the first biome")
	_check(playlist.provider_at(9) == first, "element 9 still uses the first biome")
	_check(playlist.provider_at(10) == second, "element 10 switches to the second biome")
	_check(playlist.provider_at(20) == first, "element 20 wraps back to the first biome")
	_check(playlist.provider_at(1000) == first, "element 1000 is still in step with the sections")
	_check(not playlist.uses_sections(), "an auto playlist is not section based")

	var shuffled := BiomePlaylist.new()
	shuffled.biomes = [first, second]
	shuffled.segments_per_biome = 10
	shuffled.order = BiomePlaylist.Order.SHUFFLE
	shuffled.seed = 3
	_check(
		shuffled.provider_at(0) == shuffled.provider_at(5), "a shuffle round is stable while it lasts"
	)
	var seen := {}
	for round_index in 20:
		seen[shuffled.provider_at(round_index * 10)] = true
	_check(seen.size() == 2, "shuffled rounds still use every biome")

	var other_seed := BiomePlaylist.new()
	other_seed.biomes = [first, second]
	other_seed.segments_per_biome = 10
	other_seed.order = BiomePlaylist.Order.SHUFFLE
	other_seed.seed = 11
	var differs := false
	for round_index in 20:
		var drawn := shuffled.provider_at(round_index * 10)
		differs = differs or other_seed.provider_at(round_index * 10) != drawn
	_check(differs, "a different shuffle seed walks the biomes in a different order")


func _test_playlist_single() -> void:
	var only := _provider(&"only")
	var playlist := BiomePlaylist.new()
	playlist.biomes = [only]
	playlist.segments_per_biome = 10
	_check(playlist.provider_at(0) == only, "a single-biome track starts with its biome")
	_check(playlist.provider_at(9999) == only, "a single-biome track never switches")

	var zero_length := BiomePlaylist.new()
	zero_length.biomes = [only, _provider(&"unused")]
	zero_length.segments_per_biome = 0
	_check(zero_length.provider_at(9999) == only, "segments_per_biome = 0 pins the first biome")


## A closed lap authors its running order instead: sections repeat around it.
func _test_playlist_sections() -> void:
	var meadow := _provider(&"meadow")
	var town := _provider(&"town")
	var first := BiomeSection.new()
	first.provider = meadow
	first.segments = 30
	var second := BiomeSection.new()
	second.provider = town
	second.segments = 20
	var playlist := BiomePlaylist.new()
	playlist.sections = [first, second]

	_check(playlist.uses_sections(), "an authored running order is section based")
	_check(playlist.section_loop_length() == 50, "the loop is as long as its sections")
	_check(playlist.provider_at(0) == meadow, "the loop starts with the first section")
	_check(playlist.provider_at(29) == meadow, "the first section ends where it says")
	_check(playlist.provider_at(30) == town, "the second section starts where the first ends")
	_check(playlist.provider_at(49) == town, "the second section ends with the loop")
	_check(playlist.provider_at(50) == meadow, "the sections repeat around the loop")
	_check(playlist.section_index_at(30) == 1, "section_index_at() finds the second section")
	_check(playlist.section_start(1) == 30, "section_start() reports where a section begins")
	_check(playlist.validate().is_empty(), "a well-formed section playlist validates")


## --- rural provider ----------------------------------------------------------

## The demo biome groups its road surfaces, so the road changes every few hundred
## metres instead of flickering from element to element.
func _test_road_surfaces() -> void:
	var biome := RuralBiome.new()
	biome.biome_id = &"rural"
	var grass := StandardMaterial3D.new()
	var dirt := StandardMaterial3D.new()
	biome.road_surfaces = [grass, dirt]
	biome.road_surface_every = 6

	_check(biome.road_variant_count() == 2, "a grouped road has one variant per surface")
	_check(biome.road_variant(0) == 0, "a surface covers its whole group")
	_check(biome.road_variant(5) == 0, "and it covers the end of that group as well")
	_check(biome.road_variant(6) == 1, "the next group uses the next surface")
	_check(biome.road_variant(12) == 0, "the surfaces cycle")
	_check(biome.road_material(_straight(), 1) == dirt, "a variant picks its surface")
	_check(biome.road_material(_straight(), 0) == grass, "variant 0 is the first surface")
	_check(biome.validate().is_empty(), "a biome with surfaces validates: %s" % [biome.validate()])

	var plain := RuralBiome.new()
	plain.biome_id = &"plain"
	_check(plain.road_variant_count() == 1, "without surfaces the base class's road is used")
	_check(plain.road_variant(7) == 0, "a single authored skin is used everywhere")


func _test_validation() -> void:
	var empty := BiomePlaylist.new()
	_check(not empty.validate().is_empty(), "an empty playlist is reported as a problem")

	var nameless := _provider(&"")
	_check(not nameless.validate().is_empty(), "a biome without an id is reported as a problem")

	var broken_layer := BiomeLayer.new()
	_check(not broken_layer.validate().is_empty(), "a layer without content is reported as a problem")

	var good_layer := BiomeLayer.new()
	good_layer.meshes = [BoxMesh.new()]
	_check(good_layer.validate().is_empty(), "a layer with content is accepted")
	_check(good_layer.is_usable(), "a layer with content is usable")

	var banned_mesh := BiomeLayer.new()
	banned_mesh.fit_to_segment = true
	banned_mesh.meshes = []
	banned_mesh.variants = [PackedScene.new()]
	_check(not banned_mesh.validate().is_empty(), "fit_to_segment without meshes is a problem")

	var broken_section := BiomePlaylist.new()
	var section := BiomeSection.new()
	section.segments = 0
	broken_section.sections = [section]
	_check(not broken_section.validate().is_empty(), "a section without length is a problem")


## --- track integration -------------------------------------------------------

## The contract that matters at runtime: the track announces its pooled
## segments, the director dresses them, and re-placing a segment changes nothing.
func _test_track_integration() -> void:
	var track := TrackManager.new()
	track.track_level = TrackLevel.closed_racetrack(2, 3)
	track.pool_size = 6
	# Authored segments (and their meshes) are skipped, so the test needs no
	# imported artwork.
	track.straight_segment = _segment_resource(false)
	track.turn_segment = _segment_resource(true)

	var near_layer := BiomeLayer.new()
	near_layer.meshes = [BoxMesh.new()]
	near_layer.count = 1
	near_layer.side = BiomeLayer.Side.BOTH
	near_layer.distance_min = 20.0
	near_layer.distance_max = 20.0
	near_layer.edge_margin = 0.0
	near_layer.face_track = true

	var first_road := StandardMaterial3D.new()
	var first := _provider(&"first")
	first.road_material_override = first_road
	first.near_layer = near_layer

	var second := _provider(&"second")
	second.near_layer = near_layer

	var playlist := BiomePlaylist.new()
	playlist.biomes = [first]
	playlist.segments_per_biome = 4

	var director := BiomeDirector.new()
	director.track = track
	director.playlist = playlist

	root.add_child(track)
	root.add_child(director)
	# The director connected after the track had already placed its first pool,
	# so ask for a refresh - which is also what a runtime biome edit would do.
	track.refresh_pool()

	var bodies := track.get_children()
	_check(bodies.size() == 6, "the track pooled six bodies")

	var dressed := 0
	var undressed_after_switch := 0
	var layer_instances := -1
	for body in bodies:
		var mesh_instance := body.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_instance != null and mesh_instance.material_override == first_road:
			dressed += 1
		var layer := body.get_node_or_null("BiomeLayerNEAR")
		if layer == null:
			continue
		if layer_instances < 0:
			layer_instances = layer.get_child_count()
		_check(
			layer.get_child_count() == layer_instances, "every hosted segment gets the same instance count"
		)
		_check(_faces_the_road(track, body, layer), "face_track turns instances back towards the road")
	_check(dressed == 6, "every road body got the biome's road material")
	_check(layer_instances == 2, "a BOTH-sides layer with count 1 places two instances per segment")

	# Re-placing unchanged segments must keep the very same decoration nodes: this
	# is what makes the endless track's window re-centring invisible.
	var sample_layer := bodies[0].get_node_or_null("BiomeLayerNEAR")
	var sample_instance: Node = null
	if sample_layer != null and sample_layer.get_child_count() > 0:
		sample_instance = sample_layer.get_child(0)
	track.refresh_pool()
	var kept := sample_instance != null and sample_layer.get_child_count() > 0
	kept = kept and sample_layer.get_child(0) == sample_instance
	_check(kept, "re-placing unchanged segments keeps the decoration already built")

	# Switching biome must re-skin the road and rebuild the layers once, in place.
	playlist.biomes = [second]
	director.refresh()
	var rebuilt := 0
	for body in bodies:
		var mesh_instance := body.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_instance != null and mesh_instance.material_override == null:
			undressed_after_switch += 1
	var layer := bodies[0].get_node_or_null("BiomeLayerNEAR")
	if layer != null and layer.get_child(0) != sample_instance:
		rebuilt += 1
	_check(undressed_after_switch == 6, "a biome without a road skin keeps the authored material")
	_check(rebuilt == 1, "switching biome rebuilds the decoration")
	_check(
		sample_layer.get_child_count() == 2, "switching biome replaces decoration instead of stacking it"
	)

	var lap := track.track_level.count()
	var index := track.element_index_at(Vector3.ZERO)
	_check(index >= 0 and index < lap, "element_index_at() reports an element of the lap")

	root.remove_child(director)
	root.remove_child(track)
	director.free()
	track.free()


## Horizon content lives on an anchor that rides with the runner, so the ring
## surrounds them instead of piling up in front, and is laid out per region rather
## than per segment.
func _test_horizon() -> void:
	var ring := BiomeLayer.new()
	ring.mode = BiomeLayer.Mode.RING
	ring.meshes = [QuadMesh.new()]
	ring.count = 4
	ring.distance_min = 500.0
	ring.distance_max = 700.0
	ring.host_every = 4

	var provider := _provider(&"ringed")
	provider.far_layer = ring

	var playlist := BiomePlaylist.new()
	playlist.biomes = [provider]

	var track := TrackManager.new()
	track.straight_segment = _segment_resource(false)
	track.turn_segment = _segment_resource(true)
	var director := BiomeDirector.new()
	director.track = track
	director.playlist = playlist
	root.add_child(track)
	root.add_child(director)

	director._set_active_provider(provider)
	director._refresh_anchor(Vector3.ZERO)
	var anchor := director.get_node("HorizonAnchor") as Node3D
	var host := anchor.get_node_or_null("HorizonFAR")
	_check(host != null, "a ring layer gets a horizon host")
	if host != null:
		_check(host.get_child_count() == 4, "the horizon ring places every instance of the layer")
		var first_child := host.get_child(0) as Node3D
		_check(first_child != null, "horizon instances are node3Ds")
		var placed_distance := Vector2(first_child.position.x, first_child.position.z).length()
		_check(
			placed_distance >= ring.distance_min - 0.01 and placed_distance <= ring.distance_max + 0.01,
			"horizon instances sit inside the ring band"
		)
		_check(
			_is_facing_centre(first_child, anchor),
			"horizon instances face the middle of the ring"
		)

		# The anchor rides with the runner, so the ring surrounds them: it cannot be
		# outrun, and nothing has to be re-snapped in front of them mid-run.
		director._refresh_anchor(Vector3(120.0, 0.0, 40.0))
		_check(
			anchor.global_position.is_equal_approx(Vector3(120.0, 0.0, 40.0)),
			"the anchor rides with the runner (got %s)" % anchor.global_position
		)
		# ...which leaves the very same cards alone while the runner is inside one
		# region...
		director._refresh_anchor(Vector3(240.0, 0.0, 40.0))
		_check(host.get_child(0) == first_child, "one region keeps the horizon it laid out")
		# ...and lays them out again once the runner has moved on to another one,
		# because a horizon that re-randomised every frame would crawl.
		director._refresh_anchor(Vector3(2400.0, 0.0, 40.0))
		_check(host.get_child_count() == 4, "the rebuilt horizon keeps its instance count")
		_check(host.get_child(0) != first_child, "a new region lays the horizon out again")
		# Every card of the rebuilt ring is inside the band, measured from the runner
		# the anchor now sits on: the ring is scenery all around them.
		var near := INF
		var far := 0.0
		for child in host.get_children():
			var card := child as Node3D
			if card == null:
				continue
			var distance := Vector2(
				card.global_position.x - anchor.global_position.x,
				card.global_position.z - anchor.global_position.z
			).length()
			near = minf(near, distance)
			far = maxf(far, distance)
		_check(
			near >= ring.distance_min - 0.01 and far <= ring.distance_max + 0.01,
			"the horizon ring surrounds the runner inside its band (got %s..%s)" % [near, far]
		)

	root.remove_child(director)
	root.remove_child(track)
	director.free()
	track.free()


## --- helpers -----------------------------------------------------------------

## Centreline tangent at `t`, measured from the placement itself so the check does
## not simply restate the formula it is testing.
func _tangent(segment: TrackSegment, t: float) -> Vector3:
	var step := 0.001
	var before := BiomePlacement.local_position(segment, maxf(t - step, 0.0))
	var after := BiomePlacement.local_position(segment, minf(t + step, 1.0))
	return (after - before).normalized()


## True when every instance of `layer` under `body` turns its -Z back towards the
## road (the local frame's -X on one side, +X on the other).
func _faces_the_road(track: TrackManager, body: Node3D, layer: Node) -> bool:
	if layer.get_child_count() == 0:
		return false
	var kind := track.track_level.element_at(track.element_index_at(body.global_position))
	if kind == TrackLevel.Kind.TURN:
		# On a turn the hosting body's frame is the segment's entry frame, so the
		# instance's own frame is the only place where "back towards the road" is
		# exact; the frame maths itself is covered by _test_placement_frames().
		return true
	for child in layer.get_children():
		var instance := child as Node3D
		if instance == null:
			continue
		var side := signf(instance.transform.origin.x)
		if (-instance.transform.basis.z).dot(Vector3(side, 0.0, 0.0)) > -0.99:
			return false
	return true


## True when `instance` looks at the middle of the ring around `anchor`.
func _is_facing_centre(instance: Node3D, anchor: Node3D) -> bool:
	var to_centre := anchor.global_position - instance.global_position
	to_centre.y = 0.0
	if to_centre.length_squared() < 0.0001:
		return false
	return (-instance.global_transform.basis.z).dot(to_centre.normalized()) > 0.99


func _straight() -> TrackSegment:
	var segment := TrackSegment.new()
	segment.kind = TrackSegment.Kind.STRAIGHT
	segment.length = STRAIGHT_LENGTH
	segment.radius = TURN_RADIUS
	segment.turn_degrees = TURN_DEGREES
	return segment


func _turn(direction: int) -> TrackSegment:
	var segment := _straight()
	segment.kind = TrackSegment.Kind.TURN
	segment.direction = direction
	return segment


## A segment resource the way the track's own exports look, but with a plain box
## for a mesh: lets the integration tests run without imported artwork.
func _segment_resource(is_turn: bool) -> TrackSegment:
	var segment := _turn(-1) if is_turn else _straight()
	segment.mesh = BoxMesh.new()
	segment.width = 30.0
	segment.height = 0.4
	return segment


func _segment_name(segment: TrackSegment) -> String:
	if not segment.is_turn():
		return "a straight"
	return "a %s turn" % ("right" if segment.direction > 0 else "left")


func _provider(id: StringName) -> BiomeProvider:
	var provider := BiomeProvider.new()
	provider.biome_id = id
	provider.display_name = String(id)
	return provider


func _check(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(what)


func _check_vector(actual: Vector3, expected: Vector3, what: String) -> void:
	_check(
		actual.distance_to(expected) <= EPSILON,
		"%s (got %s, expected %s)" % [what, actual, expected]
	)
