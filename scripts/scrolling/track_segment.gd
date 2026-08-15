class_name TrackSegment
extends Resource

## Describes a single authored floor segment: its mesh plus the geometry the
## track composer needs to chain it. `end()` gives the local-space displacement
## from the segment's entry to its exit point (heading 0 at entry), and `turn()`
## the heading change across it, so chaining collapses to:
##   origin  += basis_from_heading(heading) * seg.end()
##   heading += seg.turn()

enum Kind { STRAIGHT, TURN }

@export var kind: Kind = Kind.STRAIGHT
@export var mesh: Mesh
## Track width (X extent) of the mesh.
@export var width: float = 30.0
## Vertical thickness of the collider.
@export var height: float = 0.4

## Straight geometry: centreline length.
@export var length: float = 100.0

## Turn geometry: centreline radius (authored from the mesh).
@export var radius: float = 0.0
## Arc angle magnitude covered by the turn, in degrees.
@export var turn_degrees: float = 0.0
## Which way the turn bends. -1 = left, +1 = right.
@export_enum("Left:-1", "Right:1") var direction: int = -1


func is_turn() -> bool:
	return kind == Kind.TURN


## Local-space displacement from entry to exit, heading 0 at entry.
func end() -> Vector3:
	if not is_turn():
		return Vector3(0.0, 0.0, -length)
	var phi := deg_to_rad(turn_degrees)
	return _forward(direction * phi * 0.5) * (2.0 * radius * sin(phi * 0.5))


## Heading change across the segment in radians (left negative, right positive).
func turn() -> float:
	return direction * deg_to_rad(turn_degrees) if is_turn() else 0.0


func _forward(heading: float) -> Vector3:
	return Vector3(sin(heading), 0.0, -cos(heading))
