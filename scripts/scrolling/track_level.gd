extends Resource
class_name TrackLevel

## An ordered sequence of floor elements that defines a track. Curvature is not
## described here: it *emerges* when the elements are chained consecutively.
##
## A closed loop is simply a sequence whose final element points back at the
## start; an infinite level is a sequence that never ends. Both are driven by
## `element_at(i)`.

enum Kind { STRAIGHT, TURN }

@export var elements: Array[int] = []
@export var is_closed: bool = true


## Classic racetrack template: `corner_count` rounded corners each made of
## `straights_per_corner` straights and `turns_per_corner` 5-degree turns.
static func closed_racetrack(straights_per_corner: int, turns_per_corner: int, corner_count: int = 4) -> TrackLevel:
	var l := TrackLevel.new()
	for _c in corner_count:
		for _s in straights_per_corner:
			l.elements.append(Kind.STRAIGHT)
		for _t in turns_per_corner:
			l.elements.append(Kind.TURN)
	return l


## Programmatic generator: a closed rectangle with randomized straight sides
## (opposite sides equal, four 90-degree corners) so the loop lines up exactly.
static func random_loop(rng: RandomNumberGenerator, straight_min: int = 10, straight_max: int = 30) -> TrackLevel:
	var l := TrackLevel.new()
	var a := rng.randi_range(straight_min, straight_max)
	var b := rng.randi_range(straight_min, straight_max)
	for i in 4:
		var side: int = a if (i == 0 or i == 2) else b
		for _s in side:
			l.elements.append(Kind.STRAIGHT)
		if i < 3:
			for _t in 18:
				l.elements.append(Kind.TURN)
	return l


func element_at(i: int) -> int:
	if elements.is_empty():
		return Kind.STRAIGHT
	if is_closed:
		return elements[posmod(i, elements.size())]
	return elements[clampi(i, 0, elements.size() - 1)]


func count() -> int:
	return elements.size()