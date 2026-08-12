extends Node3D

## Infinite scrolling track built around the third-person runner (Method 2).
##
## The track is decoupled from the character controller: it only *reads* the
## player's position to evaluate where the railing grid must be, and recycles
## a small pool of segments so the corridor never runs out. The player is
## snapped back to zero ~once per window so its own coordinates (and thus
## physics interpolation / downstream systems) never grow unbounded.

@export var segment_scene: PackedScene
@export var num_segments: int = 24
@export var segment_length: float = 4.0
@export var snap_z: float = -60.0
@export var player: Node3D
@export var ground: Node3D

var _segments: Array[Node3D] = []


func _ready() -> void:
	for i in num_segments:
		var seg: Node3D = segment_scene.instantiate()
		add_child(seg)
		_segments.append(seg)
	_replenish_railings(0.0)


func _physics_process(_delta: float) -> void:
	if not player or not ground:
		return

	# Recycle: derive each railing's slot from the player's travel.
	_replenish_railings(player.global_position.z)

	# Teleport the player back to zero so coordinates stay small. The world is
	# already re-derived from the player's position, so nothing visibly jumps.
	if player.global_position.z < snap_z:
		_replenish_railings(0.0)
		reset_physics_interpolation()
		player.global_position.z = 0.0
		player.reset_physics_interpolation()

	# Keep the floor under the player (free roaming in X as well).
	ground.global_position.x = player.global_position.x
	ground.global_position.z = player.global_position.z


## Places segment *i* onto a world slot derived from `pz` (the player's Z),
## wrapping indices so the pool recycles seamlessly.
func _replenish_railings(pz: float) -> void:
	var first_slot := int(floor(pz / segment_length))
	for i in num_segments:
		var slot := first_slot - i
		var idx := posmod(slot, num_segments)
		_segments[idx].position.z = float(slot) * segment_length
