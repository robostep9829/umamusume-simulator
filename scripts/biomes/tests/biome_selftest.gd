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
	_test_seed_spread()
	_test_playlist_auto()
	_test_playlist_single()
	_test_playlist_sections()
	_test_road_surfaces()
	_test_validation()
	_test_track_integration()
	_test_horizon()
	_test_debug_stats()
	_test_atmosphere()

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
		for side: float in [-1.0, 1.0]:
			var yaw: float = -side * PI * 0.5
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


## The mix has to use the whole 64-bit range. Both of its constants are above
## 2^63 - 1, and the engine refuses a hex literal that large, substituting INT64_MAX
## for it: the finaliser then multiplies by the same constant twice and every seed
## lands in the top of the range. Distinct seeds are not enough to catch that - the
## crowded ones are still distinct - so this counts the high bytes they cover.
func _test_seed_spread() -> void:
	var element_bytes := {}
	var slot_bytes := {}
	for element in 12:
		element_bytes[BiomePlacement.instance_rng(1234, 0, element, 0).seed >> 56] = true
	for slot in 8:
		slot_bytes[BiomePlacement.instance_rng(1234, 0, 0, slot).seed >> 56] = true
	_check(element_bytes.size() >= 8, "12 consecutive elements spread their seeds over the "
		+ "int64 range (covered %d high bytes)" % element_bytes.size())
	_check(slot_bytes.size() >= 5, "8 slots of one element spread their seeds over the "
		+ "int64 range (covered %d high bytes)" % slot_bytes.size())


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

	# The half of validation that catches a layer which looks right and does nothing:
	# `variants` win over `meshes`, a MultiMesh can only draw one mesh, and
	# `mesh_material` never touches a scene. Each has to be named in the report, or
	# the author is left looking at a prop that never appears.
	var shadowed := BiomeLayer.new()
	shadowed.variants = [PackedScene.new()]
	shadowed.meshes = [BoxMesh.new(), BoxMesh.new()]
	shadowed.multimesh = true
	shadowed.mesh_material = StandardMaterial3D.new()
	_check_problem(shadowed, "the scenes win", "meshes that scenes shadow are reported")
	_check_problem(shadowed, "never built", "a MultiMesh that is never built is reported")
	_check_problem(shadowed, "mesh_material", "a material that is never applied is reported")

	var unreachable := BiomeLayer.new()
	unreachable.meshes = [BoxMesh.new()]
	unreachable.distance_max = 200.0
	unreachable.visible_range = 120.0
	_check_problem(unreachable, "never visible", "a layer culled inside its own band is reported")

	var low_ring := BiomeLayer.new()
	low_ring.mode = BiomeLayer.Mode.RING
	low_ring.meshes = [BoxMesh.new()]
	low_ring.distance_min = 60.0
	low_ring.distance_max = 120.0
	low_ring.fit_to_segment = true
	_check_problem(low_ring, "driven past", "a ring close enough to drive past is reported")
	_check_problem(low_ring, "RING ignores", "fit_to_segment in RING mode is reported")

	var half_filled := _provider(&"half")
	half_filled.road_skins = [StandardMaterial3D.new(), null]
	half_filled.obstacle_skins = [PackedScene.new(), null]
	_check_problem(half_filled, "road_skins", "an empty road skin slot is reported")
	_check_problem(half_filled, "obstacle_skins", "an empty obstacle skin slot is reported")

	var two_sources := BiomePlaylist.new()
	two_sources.biomes = [_provider(&"only")]
	two_sources.sections = [section_of(_provider(&"only"), 5)]
	two_sources.segments_per_biome = -1
	_check_problem(two_sources, "sections win", "biomes shadowed by sections are reported")
	_check_problem(two_sources, "negative", "a negative round length is reported")

	# And the reporting itself: the same problem is printed once, however many times
	# the failing code path runs (a pooled body is re-dressed every element).
	var reporter := BiomeDirector.new()
	reporter._report_once(&"same", "one")
	reporter._report_once(&"same", "two")
	reporter._report_once(&"other", "three")
	_check(reporter.reported_problems().size() == 2, "a repeated problem is reported once")


## The problems `resource` reports, joined, for substring checks. Taken as a
## [Variant] so the same helper serves a playlist, a biome and a layer - `Resource`
## has no `validate()` of its own, and a typed call would be refused by the analyzer.
func _problems_of(resource: Variant) -> String:
	return "\n".join(resource.validate())


func _check_problem(resource: Variant, fragment: String, what: String) -> void:
	_check(_problems_of(resource).contains(fragment), "%s (it did not mention \"%s\")"
		% [what, fragment])


func section_of(provider: BiomeProvider, segments: int) -> BiomeSection:
	var section := BiomeSection.new()
	section.provider = provider
	section.segments = segments
	return section


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


## The debug overlay reads the biome system through these: the run a biome covers,
## how far the next change is, and the state dictionary itself.
func _test_debug_stats() -> void:
	var first := _provider(&"first")
	var second := _provider(&"second")
	var playlist := BiomePlaylist.new()
	playlist.biomes = [first, second]
	playlist.segments_per_biome = 4

	_check(playlist.run_range_at(0) == Vector2i(0, 4), "a run starts where its round does")
	_check(playlist.run_range_at(3) == Vector2i(0, 4), "the last element of a round is in it")
	_check(playlist.run_range_at(4) == Vector2i(4, 4), "the next round is a run of its own")
	_check(not playlist.is_single_biome(), "a two-biome playlist does change biome")

	var single := BiomePlaylist.new()
	single.biomes = [first]
	_check(single.is_single_biome(), "a one-biome playlist never changes biome")
	single.biomes = [first, second]
	single.segments_per_biome = 0
	_check(single.is_single_biome(), "segments_per_biome = 0 pins the first biome")
	var same_everywhere := BiomePlaylist.new()
	var only := BiomeSection.new()
	only.provider = first
	only.segments = 25
	same_everywhere.sections = [only]
	_check(same_everywhere.is_single_biome(), "sections that all name one biome never change")

	var track := TrackManager.new()
	track.infinite = true
	# Fixed section lengths, so the end of the first straight run is known without
	# knowing the generator's RNG: elements 0-9 are straights, 10-15 are turns.
	track.straight_min = 10
	track.straight_max = 10
	track.turn_min = 6
	track.turn_max = 6
	track.straight_segment = _segment_resource(false)
	track.turn_segment = _segment_resource(true)
	var runner := Node3D.new()
	track.player = runner
	var director := BiomeDirector.new()
	director.track = track
	director.playlist = playlist
	root.add_child(track)
	root.add_child(runner)
	root.add_child(director)

	director._set_active_provider(first)
	# An endless track spent entirely on straights at the start, so element 0 is
	# 100 m long and the four elements of the run are exactly 400 m.
	_check(track.is_endless(), "the test track is an endless one")
	_check(is_equal_approx(track.element_length_at(0), 100.0), "a straight is 100 m long")
	_check(track.element_direction_at(0) == 0, "a straight has no direction")
	_check(
		is_equal_approx(track.element_length_at(10), deg_to_rad(5.0) * 1200.0),
		"a 5 degree turn of 1200 m radius is 104.72 m of arc"
	)
	_check(absi(track.element_direction_at(11)) == 1, "a turn bends to one side or the other")

	var stats := director.debug_stats()
	_check(stats["biome"] == &"first", "the stats name the active biome")
	_check(stats["elements"] == 0, "the runner at the origin is on element 0")
	_check(is_zero_approx(stats["progress"]), "the runner at the origin is at the element's entry")
	_check(stats["change_elements"] == 4, "the change is four elements away")
	_check(
		is_equal_approx(stats["change_distance"], 400.0),
		"four 100 m elements are 400 m (got %s)" % stats["change_distance"]
	)
	_check(stats["next_biome"] == &"second", "the next biome is the other one")
	_check(stats["run_elements"] == 4, "the run is one round long")
	_check(is_zero_approx(stats["run_progress"]), "the run has just started")
	_check(director.elements_to_biome_change() == 4, "elements_to_biome_change() agrees")
	_check(
		is_equal_approx(director.distance_to_biome_change(), 400.0),
		"distance_to_biome_change() agrees"
	)
	var upcoming: Array[Dictionary] = stats["upcoming"]
	_check(upcoming.size() == 3, "the stats look three runs ahead")
	if upcoming.size() == 3:
		_check(
			upcoming[0]["id"] == &"second" and upcoming[1]["id"] == &"first",
			"the upcoming runs start after the current one and alternate"
		)
		_check(upcoming[0]["elements"] == 4, "an upcoming run reports its length in elements")

	# Halfway through an element, half of it is left to run.
	runner.global_position = Vector3(0.0, 0.0, -50.0)
	_check(director.elements_to_biome_change() == 4, "halfway through element 0 is still element 0")
	_check(
		is_equal_approx(director.distance_to_biome_change(), 350.0),
		"distance_to_biome_change() counts the rest of the current element (got %s)"
		% director.distance_to_biome_change()
	)
	_check(
		is_equal_approx(director.debug_stats()["run_progress"], 0.125),
		"the run's progress bar is an eighth of the way along"
	)

	# One biome for the whole track: no change to wait for.
	director.playlist = single
	var flat := director.debug_stats()
	_check(flat["change_elements"] == -1, "a single-biome track reports no change")
	_check(flat["change_distance"] < 0.0, "a single-biome track reports no distance")
	_check(director.elements_to_biome_change() == -1, "elements_to_biome_change() says never")
	_check(director.distance_to_biome_change() < 0.0, "distance_to_biome_change() says never")
	_check((flat["upcoming"] as Array).is_empty(), "a single-biome track has nothing coming")

	root.remove_child(director)
	root.remove_child(track)
	root.remove_child(runner)
	director.free()
	track.free()
	runner.free()


## --- helpers -----------------------------------------------------------------

## Centreline tangent at `t`, measured from the placement itself so the check does
## not simply restate the formula it is testing.
## The part of a biome change the player sees first. Written the way the debug
## overlay reads it - through the *live* [Environment] - because "the fog did not
## change with the biome" is exactly the kind of failure a test that only looks at
## the biome's own `.tres` file cannot see.
func _test_atmosphere() -> void:
	var level := _environment(Color(0.2, 0.2, 0.25), 0.01)
	var world := WorldEnvironment.new()
	world.environment = level
	root.add_child(world)

	var day := _provider(&"day")
	day.atmosphere = _environment(Color(0.62, 0.71, 0.8), 0.0018)
	var dusk := _provider(&"dusk")
	dusk.atmosphere = _environment(Color(0.85, 0.45, 0.32), 0.0042)
	var bare := _provider(&"bare")

	var playlist := BiomePlaylist.new()
	playlist.biomes = [day, dusk, bare]
	playlist.segments_per_biome = 4
	var track := TrackManager.new()
	track.infinite = true
	track.straight_segment = _segment_resource(false)
	track.turn_segment = _segment_resource(true)
	var runner := Node3D.new()
	track.player = runner

	var director := BiomeDirector.new()
	director.track = track
	director.playlist = playlist
	director.world_environment = world
	director.environment_transition_time = 2.0
	root.add_child(track)
	root.add_child(runner)
	root.add_child(director)

	# The first biome of a run is taken as it is, however long a transition is set
	# to: fading in from the level's environment would show that look - possibly a
	# different time of day, or much denser fog - at the start of every run.
	director._set_active_provider(day)
	_check(director._blend_tween == null, "the first biome is applied without a fade")
	_check_environment(director, day.atmosphere, "the world renders the biome's fog")

	# Instant from here, so the switches below need no frames to read.
	director.environment_transition_time = 0.0
	director._set_active_provider(dusk)
	_check_environment(director, dusk.atmosphere, "the next biome's fog replaces it")
	_check(
		not director.live_environment().fog_light_color.is_equal_approx(
			day.atmosphere.fog_light_color
		),
		"the two biomes do not share a fog colour"
	)
	# A biome without an atmosphere keeps the level's own environment, and so the
	# level's fog - the rule the docs promise.
	director._set_active_provider(bare)
	_check_environment(director, level, "a biome without an atmosphere keeps the level's fog")

	# Now the same switch with a fade: the fog has to travel from the environment the
	# player is looking at to the new biome's, which is the whole point of the
	# cross-fade. The tween is stepped by hand - a self-test has no frames to spend.
	director.environment_transition_time = 2.0
	director._set_active_provider(dusk)
	var fade := director._blend_tween
	if fade == null or not fade.is_valid():
		_check(false, "entering a biome starts an atmosphere fade")
		return
	_check(director.blend_progress() < 0.5, "a fade starts at its beginning")
	# What the fade carries, as opposed to what is swapped with the resource: a fog
	# colour that is not in this list would jump instead of travelling.
	for field in [&"fog_light_color", &"fog_density", &"fog_light_energy", &"fog_sky_affect"]:
		_check(director._blend_fields.has(field), "the fade carries `%s`" % field)
	fade.custom_step(1.0)
	var halfway: Color = director.live_environment().fog_light_color
	_check(
		halfway.is_equal_approx(level.fog_light_color.lerp(dusk.atmosphere.fog_light_color, 0.5)),
		"halfway through a fade the fog is between the two biomes (got %s)" % halfway
	)
	_check(
		is_equal_approx(
			director.live_environment().fog_density,
			lerpf(level.fog_density, dusk.atmosphere.fog_density, 0.5)
		),
		"the fog density fades too"
	)
	_check(
		director.blend_progress() > 0.4 and director.blend_progress() < 0.6,
		"a fade halfway through reports about halfway (got %s)" % director.blend_progress()
	)
	fade.custom_step(1.0)
	_check_environment(director, dusk.atmosphere, "a finished fade leaves the biome's own fog")
	_check(is_equal_approx(director.blend_progress(), 1.0), "a finished fade reports itself done")

	# `fog_enabled` is the environment asset's switch and neither the director nor the
	# overlay writes to it, so a biome that leaves fog off is rendered with fog off -
	# it cuts rather than fades, which is the asset's decision to make.
	var clear := _provider(&"clear")
	clear.atmosphere = _environment(Color(0.9, 0.9, 0.95), 0.02, false)
	director.environment_transition_time = 0.0
	director._set_active_provider(clear)
	_check_environment(director, clear.atmosphere, "a biome that leaves fog off renders fog off")


## Checks the fog the world is rendering against the one a biome asked for. Every
## field is compared, because the ones that cannot be faded - `fog_enabled` among
## them - are the ones a "the fog did not change" report tends to be about.
func _check_environment(director: BiomeDirector, expected: Environment, what: String) -> void:
	var live := director.live_environment()
	if live == null:
		_check(false, "%s (no live environment)" % what)
		return
	_check(live.fog_enabled == expected.fog_enabled, "%s: fog_enabled" % what)
	_check(live.fog_light_color.is_equal_approx(expected.fog_light_color), "%s: fog colour" % what)
	_check(is_equal_approx(live.fog_density, expected.fog_density), "%s: fog density" % what)
	_check(
		is_equal_approx(live.fog_sky_affect, expected.fog_sky_affect),
		"%s: fog sky affect" % what
	)


## An environment whose fog is the only thing that matters to this test. The switch
## itself is a parameter, because "who decides whether there is fog" is one of the
## things being tested.
func _environment(colour: Color, density: float, fog: bool = true) -> Environment:
	var environment := Environment.new()
	environment.fog_enabled = fog
	environment.fog_light_color = colour
	environment.fog_density = density
	return environment


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
