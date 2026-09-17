class_name BiomePlacement
extends RefCounted

## Geometry and randomness helpers shared by [BiomeProvider] implementations and
## the [BiomeDirector].
##
## Every placement helper works in a *segment-local* frame, which is the frame
## [TrackManager] poses its floor bodies in: the segment's entry point is the
## origin, -Z points forward along the track and +X points to the right of the
## travel direction. Placement therefore never mentions world axes, and the same
## biome code is correct on the left-hand and the right-hand turns of a level -
## a biome must not care which way the track bends.
##
## Turns are walked as real arcs instead of chords, so decoration does not drift
## towards the outside of a curve.


## Arc length of `segment`'s centreline, in metres.
static func length(segment: TrackSegment) -> float:
	if segment.is_turn():
		return deg_to_rad(segment.turn_degrees) * segment.radius
	return segment.length


## Heading of the centreline at arc fraction `t` (0 = entry, 1 = exit), in
## radians, 0 meaning "straight ahead".
static func heading_at(segment: TrackSegment, t: float) -> float:
	if not segment.is_turn():
		return 0.0
	return segment.direction * deg_to_rad(segment.turn_degrees) * t


## Basis of a frame looking along the track at `heading` radians, i.e. the -Z of
## the returned basis is the travelling direction and its +X is right of the
## runner - the same frame the floor bodies are posed in.
##
## [b]A positive heading turns right[/b], which is the convention of
## [method TrackSegment._forward], [method TrackSegment.turn] and
## [method TrackManager._basis_from_heading]; this is the same rotation written
## out column by column, so decoration and the road are posed identically. Note
## that it is [i]not[/i] `Basis(Vector3.UP, heading)`: Godot's own Y rotation is
## counter-clockwise seen from above, i.e. a left turn, and mixing the two turns
## decoration the wrong way by twice the heading (10 degrees at a 5 degree turn).
static func basis_from_heading(heading: float) -> Basis:
	return Basis(
		Vector3(cos(heading), 0.0, sin(heading)),
		Vector3(0.0, 1.0, 0.0),
		Vector3(-sin(heading), 0.0, cos(heading))
	)


## Basis whose -Z follows the centreline at arc fraction `t`, optionally rotated
## by `yaw` radians around the up axis (positive `yaw` turns right, since it is
## added to the heading).
static func basis_at(segment: TrackSegment, t: float, yaw: float = 0.0) -> Basis:
	return basis_from_heading(heading_at(segment, t) + yaw)


## Position at arc fraction `t`, `lateral` metres to the right of the centreline
## (negative = to the left) and `lift` metres above it.
static func local_position(
	segment: TrackSegment, t: float, lateral: float = 0.0, lift: float = 0.0
) -> Vector3:
	var point := Vector3(0.0, 0.0, -segment.length * t)
	if segment.is_turn():
		# Point on a circle of `radius` whose centre sits to the turning side of
		# the entry, parameterised so that t = 1 lands exactly on
		# TrackSegment.end() for both turn directions.
		var theta := heading_at(segment, t)
		point = Vector3(
			segment.direction * segment.radius * (1.0 - cos(theta)),
			0.0,
			-segment.direction * segment.radius * sin(theta)
		)
	return point + basis_at(segment, t) * Vector3(lateral, 0.0, 0.0) + Vector3(0.0, lift, 0.0)


## Placement transform of one decoration instance: position from
## [method local_position], orientation from [method basis_at], plus a scale
## applied along the instance's own axes (not world axes), which is what makes
## stretched strips stay aligned with the track.
static func local_transform(
	segment: TrackSegment,
	t: float,
	lateral: float,
	lift: float,
	yaw: float,
	scale: Vector3 = Vector3.ONE
) -> Transform3D:
	var basis := basis_at(segment, t, yaw)
	if scale != Vector3.ONE:
		basis = scaled(basis, scale)
	return Transform3D(basis, local_position(segment, t, lateral, lift))


## Scales a basis along its own axes: `basis.scaled_local()`, written out
## explicitly so the rotation-scale order (rotate after scaling) is never in
## doubt.
static func scaled(basis: Basis, scale: Vector3) -> Basis:
	if scale == Vector3.ONE:
		return basis
	return Basis(basis.x * scale.x, basis.y * scale.y, basis.z * scale.z)


## Deterministic generator for one decoration instance.
##
## The same seed, layer, element index and instance slot always produce the same
## placement, so re-placing a segment (or re-hosting it on another pooled body
## when the track window slides) never shuffles its decoration around.
static func instance_rng(
	seed_value: int, layer: int, element_index: int, slot: int
) -> RandomNumberGenerator:
	var mixed := _mix(seed_value)
	mixed ^= _mix(layer + 0x9e3779b9)
	mixed ^= _mix(element_index + 0x85ebca6b)
	mixed ^= _mix(slot + 0xc2b2ae35)
	var rng := RandomNumberGenerator.new()
	rng.seed = mixed
	return rng


## Integer hash (splitmix-style) used to decorrelate the seeds above; GDScript
## ints wrap around, so this is stable on every platform.
static func _mix(value: int) -> int:
	var x := value
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb
	return x ^ (x >> 31)
