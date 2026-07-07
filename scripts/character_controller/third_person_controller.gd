@tool
extends CharacterBody3D

## Movement tuning
@export var move_speed: float = 1.6
@export var sprint_speed: float = 7.0
@export var acceleration: float = 10.0
@export var jump_velocity: float = 4.5
@export var rotation_speed: float = 12.0

## Camera tuning
@export var mouse_sensitivity: float = 0.003
@export var min_pitch: float = -60.0   # look down limit (degrees)
@export var max_pitch: float = 70.0    # look up limit (degrees)

## Sprint camera
@export var normal_spring_length: float = 1.5
@export var sprint_spring_length: float = 2.5
@export var sprint_zoom_time: float = 0.2

@export var normal_spring_position: Vector3 = Vector3(0.5, 0.0, 0.0)
@export var sprint_spring_position: Vector3 = Vector3(0.0, 0.0, 0.0)

@export var player_data: PlayerData:
	set(value):
		player_data = value
		_update_character_mesh()


# Cached node references
@onready var camera_pivot: Node3D = $CameraPivot
@onready var mesh: Node3D = $Skeleton3D
@onready var spring: Node3D = $CameraPivot/SpringArm3D
@onready var animation_tree: AnimationTree = $AnimationTree

# Gravity pulled from project settings so it stays consistent
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Camera rotation state
var _yaw: float = 0.0
var _pitch: float = 0.0

# Sprint tracking
var _sprint_timer: float = 0.0
var is_sprinting: bool = false


func _ready() -> void:
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_character_mesh()


func _update_character_mesh() -> void:
	if not player_data or not player_data.character:
		return
	var old: Node3D = get_node_or_null("Skeleton3D")
	if not old:
		return
	for child in old.get_children():
		if child is MeshInstance3D:
			old.remove_child(child)
			child.queue_free()
	var new_mesh: Node3D = player_data.character.instantiate()
	old.replace_by(new_mesh)
	old.queue_free()
	mesh = new_mesh
#	for child in mesh.get_children():
#		if child is SpringBoneSimulator3D:
#			child.setting_count = 0
	if animation_tree:
		animation_tree.set_active(false)
		animation_tree.set_active(true)
	$MorphController.wake()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))

	# Toggle mouse capture with Escape so you can click away
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_update_camera()
	_handle_movement(delta)


func _update_camera() -> void:
	# Yaw rotates the pivot horizontally, pitch tilts it vertically
	camera_pivot.rotation.y = _yaw
	camera_pivot.rotation.x = _pitch


func _handle_movement(delta: float) -> void:
	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	# Read input as a 2D vector (WASD by default)
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	# Convert input into a direction relative to where the camera faces
	var direction := Vector3.ZERO
	if input_dir != Vector2.ZERO:
		var forward := -camera_pivot.global_transform.basis.z
		var right := camera_pivot.global_transform.basis.x
		# Flatten so movement stays on the ground plane
		forward.y = 0.0
		right.y = 0.0
		direction = (forward * -input_dir.y + right * input_dir.x).normalized()

	# Choose speed based on sprint input
	is_sprinting = Input.is_action_pressed("sprint")
	var speed := sprint_speed if is_sprinting else move_speed

	if is_sprinting:
		_sprint_timer += delta
	else:
		_sprint_timer = 0.0

	var target_length := sprint_spring_length if _sprint_timer >= sprint_zoom_time else normal_spring_length
	spring.spring_length = lerpf(spring.spring_length, target_length, 3 * delta)
	var target_offset := sprint_spring_position if _sprint_timer >= sprint_zoom_time else normal_spring_position
	spring.position = lerp(spring.position, target_offset, acceleration * delta)
	
	# Smoothly accelerate toward the target horizontal velocity
	var target_velocity := direction * speed
	velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta)

	# Rotate the mesh to face movement direction
	if direction != Vector3.ZERO:
		var target_yaw := atan2(direction.x, direction.z)
		mesh.rotation.y = lerp_angle(mesh.rotation.y, target_yaw, rotation_speed * delta)
	
	move_and_slide()
