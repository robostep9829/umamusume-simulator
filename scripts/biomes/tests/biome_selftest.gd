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
## It is written to fail loudly rather than to pass quietly: a project script that does
## not compile is reported before a single test runs, every test returns `true` from its
## last line so the runner can tell one that finished from one a runtime error abandoned
## part way, a test that asserts nothing is counted as a failure, and a run that dies
## before the end never prints a summary - because a self-test that says "all green"
## about tests it did not run is worse than no self-test at all.
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
# Set by the first frame; see _process.
var _ran: bool = false
var _finished: bool = false
# Tests that ran to their end, for the summary: a smaller number than the list says
# something stopped early, even when every check that did run passed.
var _finished_tests: int = 0


## The tests run from the first `_process`, not from `_initialize`, because of *when*
## the root enters the tree: `SceneTree::initialize()` runs the main loop's
## `_initialize()` and only then does `root->_set_tree(this)`, so a node added during
## `_initialize()` never enters the tree and never gets its `_ready()`. Half of these
## tests build a track or a director and then read what its `_ready()` made - the
## pool, the horizon anchor, the level environment - and a director that is not in
## the tree also cannot fade anything: a [Tween] bound to an out-of-tree node is
## stepped and silently does nothing (`Tween::step()` returns early while its bound
## node is not inside the tree). One frame later the tree is up and everything behaves
## the way the game does.
func _process(_delta: float) -> bool:
	if _ran:
		# Never hang: if a script error stopped the run before it reported, the second
		# frame ends it - and the missing "self-test:" line is the tell.
		return true
	_ran = true
	_run_tests()
	if not _finished:
		printerr("biome self-test: the run stopped before it finished; see the errors above")
		quit(1)
	return true


## True while every project script the tests build can be instantiated.
##
## A script that does not compile - its own parse error, or the parse error of a
## script it depends on - still loads: `ResourceFormatLoaderGDScript::load()` returns
## the invalid resource on purpose ("Don't fail loading because of parsing error"),
## and the class it declares resolves to that same broken resource. Calling `.new()`
## on one is then refused inside the engine (`GDScript::_new` bails with an invalid
## script and GDScript reports it as "Nonexistent function 'new' in base 'GDScript'"),
## which aborts whichever test made the call - so the failure shows up as tests that
## silently did not run. `can_instantiate()` is the engine's own `valid` flag, the same
## one `--script` checks before it will run a main loop at all.
func _dependencies_ready() -> bool:
	var paths: Array[String] = [
		"res://scripts/scrolling/track_manager.gd",
		"res://scripts/scrolling/track_segment.gd",
		"res://scripts/scrolling/track_level.gd",
		"res://scripts/scrolling/infinite_track_level.gd",
		"res://scripts/biomes/biome_provider.gd",
		"res://scripts/biomes/biome_layer.gd",
		"res://scripts/biomes/biome_playlist.gd",
		"res://scripts/biomes/biome_section.gd",
		"res://scripts/biomes/biome_director.gd",
		"res://scripts/biomes/biome_placement.gd",
		"res://scripts/biomes/providers/rural_biome.gd",
	]
	var broken := PackedStringArray()
	for path in paths:
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			broken.append(path)
	if broken.is_empty():
		return true
	printerr(
		"biome self-test: %d project script(s) cannot be compiled, so the tests that "
		% broken.size()
		+ "build them cannot run:"
	)
	for broken_path in broken:
		printerr("  - %s" % broken_path)
	printerr("biome self-test: fix the errors above and run again.")
	return false


func _run_tests() -> void:
	# Reported first and alone: a script that does not compile makes every test that
	# builds one of its classes stop at its first statement, and the run below would
	# otherwise report "all green" with those tests missing. The engine prints the
	# parse error itself when the script is loaded; this says which file to look at.
	if not _dependencies_ready():
		_finished = true
		quit(1)
		return

	# The precondition for the tests that build nodes, checked before them so that a
	# harness moved back into `_initialize()` reports one clear line - and skips what
	# cannot work - instead of failing seventeen checks about an empty track.
	var tree_ready := root.is_inside_tree()

	# Listed rather than called one by one, so the log says which test is running when
	# an engine error lands between two checks. Every test is `-> bool` and ends with
	# `return true`; the runner reads that back to tell a test that finished from one a
	# runtime error abandoned half way.
	var tests: Array[Callable] = [
		_test_placement_end_points,
		_test_placement_frames,
		_test_placement_mirrors,
		_test_placement_lateral,
		_test_placement_determinism,
		_test_spawn_gate_determinism,
		_test_seed_spread,
		_test_playlist_auto,
		_test_playlist_single,
		_test_playlist_sections,
		_test_road_surfaces,
		_test_validation,
	]
	if tree_ready:
		tests.append_array(_tree_tests())
	else:
		# A failure, not a log line: the run exits non-zero, and it says which tests it
		# never ran, because "all green" about a third of the suite that did not run is
		# the exact thing this file is written not to do.
		var skipped: Array[String] = []
		for tree_test in _tree_tests():
			skipped.append(tree_test.get_method())
		_failures.append(
			"the tree is not running, so %d tests never ran: %s"
			% [skipped.size(), ", ".join(skipped)]
		)
	for test in tests:
		var before := _checks
		var test_name := test.get_method()
		print("  · %s" % test_name)
		# A test that hits a runtime error does not run to the end - GDScript abandons
		# the call and returns nothing from it - so every test ends with `return true`
		# and the runner reads that back. Without it a test can lose half its checks to
		# one bad expression and the run still says "all green": that is exactly what
		# happened to _test_pool_ring, which reported a Dictionary against an Array and
		# quietly skipped every check after it.
		# (`return` with no value is legal in a `-> bool` function - nil is converted -
		# so this also catches a test that bails out of its own accord, which is what
		# _test_atmosphere does when the fade it is about to measure never started.)
		var finished: Variant = test.call()
		if finished != true:
			_failures.append(
				"%s did not reach its end: a runtime error abandoned it or it returned "
				% test_name
				+ "early (see the errors above)"
			)
		else:
			_finished_tests += 1
		# A test that asserted nothing is a test that did nothing, whether it reached
		# its end or not.
		if _checks == before:
			_failures.append(
				"%s added no checks: every test here asserts something" % test_name
			)

	print("")
	if _failures.is_empty():
		print("biome self-test: %d checks in %d tests, all green." % [_checks, _finished_tests])
	else:
		# stderr, both lines: a CI job that splits the streams must show why it went red,
		# not just that it did.
		printerr("biome self-test: %d checks in %d of %d tests, %d FAILED" % [
			_checks, _finished_tests, tests.size(), _failures.size()
		])
		for failure in _failures:
			printerr("  - %s" % failure)
	_finished = true
	quit(0 if _failures.is_empty() else 1)


## The tests that build nodes, and so only work once the root is in the tree (see
## [_process]). A separate list so a run that lost that frame can name the tests it
## skipped rather than reporting a shorter suite as a passing one.
func _tree_tests() -> Array[Callable]:
	return [
		_test_first_pool,
		_test_pool_ring,
		_test_track_integration,
		_test_horizon,
		_test_debug_stats,
		_test_atmosphere,
	]


## --- placement ---------------------------------------------------------------

## t = 1 must land on the segment's authored exit point, for every segment kind
## and both turn directions.
func _test_placement_end_points() -> bool:
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
		var expected_length := STRAIGHT_LENGTH
		if segment.is_turn():
			# The arc, not the chord: written as the formula so a change to the turn's
			# authored constants moves this expectation with it.
			expected_length = deg_to_rad(TURN_DEGREES) * TURN_RADIUS
		_check(
			is_equal_approx(BiomePlacement.length(segment), expected_length),
			"arc length of %s is the centreline length" % _segment_name(segment)
		)
	return true


## The frame a decoration is posed in must follow the centreline: its -Z is the
## direction of travel and its +X stays right of the runner. Without this, a layer
## sits at the right place but faces the wrong way on every curve, which is
## exactly what a mirrored heading convention produces.
func _test_placement_frames() -> bool:
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
			# absf: a right axis pointing *back* along the travel would be as wrong as
			# one pointing forward, and a signed comparison would pass it.
			_check(
				absf(frame.x.dot(tangent)) < FRAME_EPSILON,
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
	return true


## A left-hand turn is the mirror image of a right-hand turn: a layer must not
## have to care which way the track bends.
func _test_placement_mirrors() -> bool:
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
	return true


## Lateral offsets stay perpendicular to the track and keep their distance.
func _test_placement_lateral() -> bool:
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
	return true


## Decoration must be reproducible: recycling a segment may not shuffle it.
func _test_placement_determinism() -> bool:
	var a := BiomePlacement.instance_rng(7, 2, 1234, 1).randf()
	var b := BiomePlacement.instance_rng(7, 2, 1234, 1).randf()
	var c := BiomePlacement.instance_rng(7, 2, 1235, 1).randf()
	var d := BiomePlacement.instance_rng(7, 3, 1234, 1).randf()
	_check(a == b, "the same placement request always yields the same random value")
	_check(a != c, "a different element yields a different random value")
	_check(a != d, "a different layer yields a different random value")
	return true


## Whether an element is hosted at all is a decision the gate in
## [method BiomeDirector._build_along_track] takes from a period drawn between
## `frequency_min` and `frequency_max`. It has to come from the layer seed and the
## element index: a pooled body re-hosts an element when the track window slides, and
## a period drawn from the global RNG would skip an element it built the first time,
## which reads as the scenery reshuffling. The authored near layer is the one asset
## that uses a range (`frequency_max = 6` in `rural_near.tres`), so this mirrors it
## rather than the 1/1 every other test runs with - and 1/1 cannot catch this at all,
## because every element is hosted whatever the period is.
func _test_spawn_gate_determinism() -> bool:
	var layer := BiomeLayer.new()
	layer.meshes = [BoxMesh.new()]
	layer.count = 1
	layer.side = BiomeLayer.Side.LEFT
	layer.frequency_min = 1
	layer.frequency_max = 6
	layer.distance_min = 20.0
	layer.distance_max = 20.0
	var director := BiomeDirector.new()
	director.decor_seed = 987654321
	var segment := _straight()
	var identical := true
	var hosted := 0
	for element in 24:
		var first := _gate_signature(director, layer, segment, element)
		var second := _gate_signature(director, layer, segment, element)
		identical = identical and first == second
		if first != "":
			hosted += 1
	_check(identical, "the same element builds the same decoration twice over (24 elements)")
	# Without these the check above passes for a gate that hosts everything, which is
	# what every other layer in the suite does.
	_check(hosted > 0, "a 1..6 period hosts something in 24 elements (got %d)" % hosted)
	_check(hosted < 24, "and skips something in 24 elements (got %d)" % hosted)
	return true


## The decoration one element would get, spelled as the transforms of the nodes the
## director placed for it - so two builds of it can be compared for equality. The
## class is named rather than the node, because an out-of-tree node gets an engine
## counter for its name (`@MeshInstance3D@7`) that says nothing about the placement.
func _gate_signature(
	director: BiomeDirector, layer: BiomeLayer, segment: TrackSegment, element: int
) -> String:
	var host := Node3D.new()
	director._build_along_track(host, layer, segment, element, BiomeProvider.Layer.NEAR)
	var signature := ""
	for child in host.get_children():
		signature += "%s|%s\n" % [child.get_class(), (child as Node3D).transform]
	host.free()
	return signature


## The mix has to use the whole 64-bit range. Both of its constants are above
## 2^63 - 1, and the engine refuses a hex literal that large, substituting INT64_MAX
## for it: the finaliser then multiplies by the same constant twice and every seed
## lands in the top of the range. Distinct seeds are not enough to catch that - the
## crowded ones are still distinct - so this counts the high bytes they cover.
func _test_seed_spread() -> bool:
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
	return true


## --- playlists ---------------------------------------------------------------

func _test_playlist_auto() -> bool:
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
	return true


func _test_playlist_single() -> bool:
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
	return true


## A closed lap authors its running order instead: sections repeat around it.
func _test_playlist_sections() -> bool:
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
	return true


## --- rural provider ----------------------------------------------------------

## The demo biome groups its road surfaces, so the road changes every few hundred
## metres instead of flickering from element to element.
func _test_road_surfaces() -> bool:
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
	return true


func _test_validation() -> bool:
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
	# The console shows the first and third of these as errors - they are this test
	# printing on purpose, and the second call must not print at all.
	reporter._report_once(&"same", "self-test: the first report of \"same\" (expected)")
	reporter._report_once(&"same", "self-test: the second report of \"same\" is swallowed")
	reporter._report_once(&"other", "self-test: the first report of \"other\" (expected)")
	_check(reporter.reported_problems().size() == 2, "a repeated problem is reported once")

	# And the one thing a layer cannot check about itself: a `prop_priorities` entry that
	# names no node of the props the layer spawns is a priority that would be silently never
	# applied, and only the director holds the map and the node names at the same time.
	var before := reporter.reported_problems().size()
	var prop_node := Node3D.new()
	prop_node.name = "Prop"
	var canopy := MeshInstance3D.new()
	canopy.name = "Leaves"
	prop_node.add_child(canopy)
	canopy.owner = prop_node
	var prop_scene := PackedScene.new()
	prop_scene.pack(prop_node)
	var naming := BiomeLayer.new()
	naming.meshes = [BoxMesh.new()]
	naming.override_render_priority = true
	naming.prop_priorities = {"Leaves": 0, "Leaf": 1}
	reporter._report_unknown_prop_names(prop_node, prop_scene, naming)
	_check(
		reporter.reported_problems().has(&"prop_priority_name::Leaf"),
		"a prop priority that names no node of the prop is reported"
	)
	_check(
		not reporter.reported_problems().has(&"prop_priority_name::Leaves"),
		"the name the prop does answer to is not reported"
	)
	naming.prop_priorities = {"Leaves": 0}
	reporter._report_unknown_prop_names(prop_node, prop_scene, naming)
	_check(
		reporter.reported_problems().size() == before + 1,
		"a map the props answer to adds no report"
	)
	prop_node.free()
	reporter.free()
	return true


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
func _test_track_integration() -> bool:
	var track := _racetrack(2, 3, 6)

	var near_layer := _box_layer(1)
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

	var world := _level_world()
	var director := _wired_director(track, playlist, world)

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

	_teardown([director, track, world])
	return true


## The order a level is wired in: `TrackManager` first, so it places its whole
## first pool in its own `_ready()` - which runs before the director's, because
## children are readied in tree order - and announces it to nobody. In a closed
## loop the next physics frame re-announces everything, so this only ever showed in
## endless mode, where nothing announces the pool again until the window re-centres
## about 26 elements later: the run opens on a bare track and the overlay's `layers`
## line reads `near 0`, `mid 0` and `far 0` the whole time.
func _test_first_pool() -> bool:
	var track := _endless_track(1, 2, 1, 2, 6)

	var road := StandardMaterial3D.new()
	var near_layer := _box_layer(1)

	var ring := BiomeLayer.new()
	ring.mode = BiomeLayer.Mode.RING
	ring.meshes = [QuadMesh.new()]
	ring.count = 4
	ring.distance_min = 500.0
	ring.distance_max = 700.0
	ring.visible_range = 800.0

	var provider := _provider(&"first")
	provider.road_material_override = road
	provider.near_layer = near_layer
	provider.far_layer = ring
	var playlist := BiomePlaylist.new()
	playlist.biomes = [provider]

	var world := _level_world()
	var runner := Node3D.new()
	track.player = runner
	var director := _wired_director(track, playlist, world)

	# The scene file's order: the track and its player enter the tree first, so the
	# window is placed - and announced - while nothing is listening yet.
	root.add_child(track)
	root.add_child(runner)
	_check(
		int(_layer_counts(director)["near"]) == 0,
		"the track places its first pool before anything is listening"
	)

	root.add_child(director)
	_check(
		int(_layer_counts(director)["near"]) == 12,
		"a director that joins late decorates the pool it found (got %d)"
		% int(_layer_counts(director)["near"])
	)
	_check(int(_layer_counts(director)["mid"]) == 0, "a band with no layer stays empty")
	_check(_count_road_bodies(track, road) == 6, "and skins every road body it found")

	# A ring band is built on the horizon anchor instead of on the segment bodies, so
	# its count has to come from there too - otherwise `far` reads 0 for every biome
	# whose horizon is a ring, whatever the world actually contains.
	director._set_active_provider(provider)
	director._refresh_anchor(Vector3.ZERO)
	_check(int(_layer_counts(director)["far"]) == 4, "a ring band counts its cards on the anchor")
	_check(
		int(_layer_counts(director)["near"]) == 12, "and leaves the along-track bands alone"
	)

	_teardown([director, runner, track, world])
	return true


## A window that moves re-dresses the elements that entered it, and nothing else.
##
## The pool is keyed by the window slot each body carries, counted absolutely, so the
## elements a re-centre keeps stay on the body they are already dressed on and the
## director skips them - see [method TrackManager._body_for_slot]. This is the
## difference between a re-centre costing six elements and costing the pool: the demo
## level holds 280 instanced tree scenes, and rebuilding all of them in one frame is
## the freeze this test locks down.
func _test_pool_ring() -> bool:
	var track := _endless_track(1, 1, 1, 1, 6)
	var runner := Node3D.new()
	track.player = runner

	var layer := _box_layer(1, BiomeLayer.Side.LEFT)
	var provider := _provider(&"ringed")
	provider.near_layer = layer
	var playlist := BiomePlaylist.new()
	playlist.biomes = [provider]

	var world := _level_world()
	var director := _wired_director(track, playlist, world)
	root.add_child(track)
	root.add_child(runner)
	root.add_child(director)

	var pool := track.get_node("ScrollOrigin").get_children()
	_check(pool.size() == 6, "the endless pool has one body per slot")
	var ringed := true
	for body in pool:
		var record: Dictionary = director._records.get(body.get_instance_id(), {})
		var carried := int(record.get("index", -1))
		ringed = ringed and carried >= 0 and pool[posmod(carried, pool.size())] == body
	_check(ringed, "a body carries `posmod(element_index, pool_size)`")

	var before := _worn_by(director, pool)
	var kept := 0
	var rebuilt := 0
	track._recenter(track._slot_first + 1)
	for body in pool:
		if _still_wearing(director, body, before):
			kept += 1
		else:
			rebuilt += 1
	_check(kept == 5, "a one-element move keeps five bodies as they were (got %d)" % kept)
	_check(rebuilt == 1, "and rebuilds the body whose element entered (got %d)" % rebuilt)

	# Which is what the debug readout reports, and what the overlay's `build` line shows.
	director._physics_process(0.0)
	var build := director.last_build()
	_check(int(build.get("segments", -1)) == 1, "the build readout counts the one rebuilt segment")
	_check(int(build.get("instances", -1)) == 1, "and the one instance it built for it")
	_check(int(build.get("usec", -1)) >= 0, "and says how long it took")

	_teardown([director, runner, track, world])

	# The closed loop re-places every pool on every frame, so the same ring is what
	# keeps its re-dresses down to the elements that scrolled in.
	var loop := _racetrack(2, 1, 4)
	var loop_world := _level_world()
	var loop_director := _wired_director(loop, playlist, loop_world)
	root.add_child(loop)
	root.add_child(loop_director)

	var loop_pool := loop.get_children()
	_check(loop_pool.size() == 4, "the closed loop pools four bodies")
	var loop_before := _worn_by(loop_director, loop_pool)
	# One element on: the window is indexed by the straight segment's length, which is
	# what `_seg_length` is set from, so this moves the window by exactly one slot.
	loop._replenish(STRAIGHT_LENGTH)
	var loop_kept := 0
	for body in loop_pool:
		if _still_wearing(loop_director, body, loop_before):
			loop_kept += 1
	_check(loop_kept == 3, "a step of the closed loop keeps three of four bodies (got %d)" % loop_kept)

	_teardown([loop_director, loop, loop_world])
	return true


## What every body in `bodies` is wearing right now, by body: the element it carries
## and the decoration node under its NEAR band. The node is kept as a node rather than
## as an id or a count, because identity is the whole question - a rebuild builds a
## fresh node and drops the old one, a skip leaves the very same node in place.
func _worn_by(director: BiomeDirector, bodies: Array) -> Dictionary:
	var worn := {}
	for body in bodies:
		worn[body.get_instance_id()] = {
			"index": _carried_element(director, body),
			"node": _decoration_of(body),
		}
	return worn


## True when `body` still carries the element and the very decoration node it did in
## `worn` - the two ways a body can come through a window move unchanged.
func _still_wearing(director: BiomeDirector, body: Node, worn: Dictionary) -> bool:
	var was: Dictionary = worn[body.get_instance_id()]
	var same := _carried_element(director, body) == int(was["index"])
	return same and _decoration_of(body) == was["node"]


## The element a body carries according to the director, or -1 when it has none.
func _carried_element(director: BiomeDirector, body: Node) -> int:
	var record: Dictionary = director._records.get(body.get_instance_id(), {})
	return int(record.get("index", -1))


## The first node in a body's NEAR band, or `null`.
func _decoration_of(body: Node) -> Node:
	var host := body.get_node_or_null("BiomeLayerNEAR")
	if host == null or host.get_child_count() == 0:
		return null
	return host.get_child(0)


## Horizon content lives on an anchor that rides with the runner, so the ring
## surrounds them instead of piling up in front, and is laid out per region rather
## than per segment.
func _test_horizon() -> bool:
	var ring := BiomeLayer.new()
	ring.mode = BiomeLayer.Mode.RING
	ring.meshes = [QuadMesh.new()]
	ring.count = 4
	ring.distance_min = 500.0
	ring.distance_max = 700.0
	# Past the band, or the farthest cards of the ring would be culled - which is
	# exactly what the layer's own validation reports.
	ring.visible_range = 800.0
	ring.host_every = 4

	var provider := _provider(&"ringed")
	provider.far_layer = ring

	var playlist := BiomePlaylist.new()
	playlist.biomes = [provider]

	var track := TrackManager.new()
	track.straight_segment = _segment_resource(false)
	track.turn_segment = _segment_resource(true)
	var world := _level_world()
	var director := _wired_director(track, playlist, world)
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
		# outrun, and nothing has to be re-snapped in front of them mid-run. The
		# positions are on the level's first straights, so which element they fall on
		# (12 / 100 = element 1, then 2) does not depend on how a curve resolves.
		director._refresh_anchor(Vector3(0.0, 0.0, -120.0))
		_check(
			anchor.global_position.is_equal_approx(Vector3(0.0, 0.0, -120.0)),
			"the anchor rides with the runner (got %s)" % anchor.global_position
		)
		# ...which leaves the very same cards alone while the runner is inside one
		# region (elements 0-3 are one, `host_every` = 4)...
		director._refresh_anchor(Vector3(0.0, 0.0, -240.0))
		_check(host.get_child(0) == first_child, "one region keeps the horizon it laid out")
		# ...and lays them out again once the runner has moved on to another one
		# (element 12), because a horizon that re-randomised every frame would crawl.
		director._refresh_anchor(Vector3(0.0, 0.0, -1200.0))
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

	_teardown([director, track, world])
	return true


## The debug overlay reads the biome system through these: the run a biome covers,
## how far the next change is, and the state dictionary itself.
func _test_debug_stats() -> bool:
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
	var world := _level_world()
	var director := _wired_director(track, playlist, world)
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

	_teardown([director, track, runner, world])
	return true


## --- helpers -----------------------------------------------------------------

## The part of a biome change the player sees first. Written the way the debug
## overlay reads it - through the *live* [Environment] - because "the fog did not
## change with the biome" is exactly the kind of failure a test that only looks at
## the biome's own `.tres` file cannot see.
func _test_atmosphere() -> bool:
	var world := _level_world()
	var level := world.environment

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

	var director := _wired_director(track, playlist, world)
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
		# `return false`: the test contract is "true only from the last line", and a
		# bare `return` in a `-> bool` function is a compile error in Godot - nil is a
		# hard-typed value, so it does not convert to bool.
		return false
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

	_teardown([director, track, runner, world])
	return true


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


## Centreline tangent at `t`, measured from the placement itself so the check does
## not simply restate the formula it is testing.
func _tangent(segment: TrackSegment, t: float) -> Vector3:
	var step := 0.001
	var before := BiomePlacement.local_position(segment, maxf(t - step, 0.0))
	var after := BiomePlacement.local_position(segment, minf(t + step, 1.0))
	return (after - before).normalized()


## The layer counts exactly as the debug overlay reads them - the numbers a player
## sees when the scenery is missing.
func _layer_counts(director: BiomeDirector) -> Dictionary:
	return director.debug_stats()["layers"] as Dictionary


## Pooled floor bodies drawing `material`, found by walking the track: in endless
## mode the pool hangs under the window's scroll origin rather than under the track.
func _count_road_bodies(node: Node, material: Material) -> int:
	var total := 0
	var mesh_instance := node.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_instance != null and mesh_instance.material_override == material:
		total += 1
	for child in node.get_children():
		total += _count_road_bodies(child, material)
	return total


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


## A closed racetrack with [method _segment_resource]'s stand-in meshes, so an
## integration test needs no imported artwork.
func _racetrack(straights: int, turns: int, pool_size: int) -> TrackManager:
	var track := TrackManager.new()
	track.track_level = TrackLevel.closed_racetrack(straights, turns)
	track.pool_size = pool_size
	track.straight_segment = _segment_resource(false)
	track.turn_segment = _segment_resource(true)
	return track


## An endless track with the generator's run lengths pinned, so the window a test
## sees is known rather than random. `pool_size` is spelled out at every call: the
## track's own default is a full level's worth of bodies.
func _endless_track(
	straight_min: int, straight_max: int, turn_min: int, turn_max: int, pool_size: int
) -> TrackManager:
	var track := TrackManager.new()
	track.infinite = true
	track.pool_size = pool_size
	track.straight_min = straight_min
	track.straight_max = straight_max
	track.turn_min = turn_min
	track.turn_max = turn_max
	track.straight_segment = _segment_resource(false)
	track.turn_segment = _segment_resource(true)
	return track


## A band of plain boxes beside the track - enough geometry to place, count and
## rank. A test that needs more of a layer, a wider band or instances that face the
## road, sets the extra fields on the result.
func _box_layer(count: int, side: BiomeLayer.Side = BiomeLayer.Side.BOTH) -> BiomeLayer:
	var layer := BiomeLayer.new()
	layer.meshes = [BoxMesh.new()]
	layer.count = count
	layer.side = side
	layer.distance_min = 20.0
	layer.distance_max = 20.0
	layer.edge_margin = 0.0
	return layer


## A director wired to a track, a playlist and a level environment, still out of the
## tree. Which of the three the caller adds first is left to it on purpose: several
## tests are about that order, and about whether the pool was refreshed yet.
func _wired_director(
	track: TrackManager, playlist: BiomePlaylist, world: WorldEnvironment
) -> BiomeDirector:
	var director := BiomeDirector.new()
	director.track = track
	director.playlist = playlist
	director.world_environment = world
	return director


## A level [WorldEnvironment] with a plain environment, added to the tree. Every test
## that hands its director a playlist gets one: a biome with no atmosphere falls back
## to it, and with no environment anywhere the director reports an error by design
## (see [method BiomeDirector._blend_environment]) - true, but noise in a test run.
func _level_world() -> WorldEnvironment:
	var world := WorldEnvironment.new()
	world.environment = _environment(Color(0.2, 0.2, 0.25), 0.01)
	root.add_child(world)
	return world


## Frees what a test built. `free()` takes a node's children with it, and anything left
## alive is what the engine reports as leaked instances when the run exits.
func _teardown(nodes: Array) -> void:
	for node in nodes:
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.free()


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
