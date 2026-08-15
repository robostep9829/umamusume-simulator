extends RefCounted
class_name InfiniteTrackLevel

## Procedural, endless sequence of track elements. Curvature is not authored: it
## emerges from chaining consecutive elements, and the level changes curvature
## from section to section by alternating the turn direction and varying the
## straight/curve lengths.
##
## Elements are determined purely by their index, so any window of the infinite
## track can be regenerated deterministically from a single seed.

enum Kind { STRAIGHT, TURN_LEFT, TURN_RIGHT }

var straight_min := 10
var straight_max := 30
var turn_min := 6
var turn_max := 18

var _rng := RandomNumberGenerator.new()
var _section_start: Array[int] = [0]
var _section_straight: Array[int] = []
var _section_turn: Array[int] = []
var _section_dir: Array[int] = []


func setup(seed_value: int) -> void:
	_rng.seed = seed_value


func element_at(i: int) -> int:
	while i >= _total_len():
		_append_section()
	for s in range(_section_start.size() - 2, -1, -1):
		if _section_start[s] <= i:
			var local := i - _section_start[s]
			if local < _section_straight[s]:
				return Kind.STRAIGHT
			return Kind.TURN_LEFT if _section_dir[s] > 0 else Kind.TURN_RIGHT
	return Kind.STRAIGHT


func _total_len() -> int:
	if _section_straight.is_empty():
		return 0
	return _section_start[-1]


func _append_section() -> void:
	var sl := _rng.randi_range(straight_min, straight_max)
	var tl := _rng.randi_range(turn_min, turn_max)
	var dir := 1 if _rng.randf() < 0.5 else -1
	_section_straight.append(sl)
	_section_turn.append(tl)
	_section_dir.append(dir)
	_section_start.append(_section_start[-1] + sl + tl)