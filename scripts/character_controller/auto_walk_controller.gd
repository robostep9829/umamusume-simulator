extends CharacterBody3D

@export var walk_speed: float = 1.4
@export var sprint_speed: float = 8.0
@export var acceleration: float = 10.0
@export var rotation_speed: float = 12.0
var is_sprinting: bool = true

@onready var mesh: Node3D = $Skeleton3D

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _direction: Vector3


func _ready() -> void:
	_direction = Vector3.FORWARD


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	var target_velocity := _direction * (sprint_speed if is_sprinting else walk_speed)
	velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta)

	var target_yaw := atan2(_direction.x, _direction.z)
	mesh.rotation.y = lerp_angle(mesh.rotation.y, target_yaw, rotation_speed * delta)

	move_and_slide()
