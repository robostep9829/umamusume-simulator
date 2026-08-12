@tool
extends CharacterBody3D

## Movement tuning
@export var move_speed: float = 1.6
@export var sprint_speed: float = 7.0
@export var acceleration: float = 10.0
@export var jump_velocity: float = 4.5
@export var rotation_speed: float = 12.0

# Auto run: after N seconds without any movement input the character runs
# forward on its own. Pressing "move_back" interrupts it. 0 disables.
@export var auto_run_delay: float = 0.0

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
@onready var skeleton: Node3D = $Skeleton3D
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

# Auto run tracking
var _idle_time: float = 0.0
var auto_forward: bool = false


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
	skeleton = new_mesh
	
	if player_data.spring_bone_settings:
		for child in skeleton.get_children():
			if child is SpringBoneSimulator3D:
				player_data.spring_bone_settings.apply_to(child)
				break
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


## Auto run: idle counter. Any directional input resets the clock; only
## "move_back" cancels an auto-run that is already in progress.
func _apply_auto_run(input_dir: Vector2, delta: float) -> Vector2:
	if auto_run_delay <= 0.0:
		return input_dir
	var any_move := (
		Input.is_action_pressed("move_forward")
		or Input.is_action_pressed("move_back")
		or Input.is_action_pressed("move_left")
		or Input.is_action_pressed("move_right")
	)
	if any_move:
		_idle_time = 0.0
	else:
		_idle_time += delta
		if _idle_time >= auto_run_delay:
			auto_forward = true
	if Input.is_action_just_pressed("move_back"):
		auto_forward = false
		_idle_time = 0.0
	# Force forward input while auto-running (unless the player is actively
	# holding backward, which already cancelled it this frame).
	if auto_forward and input_dir.y >= 0.0:
		return Vector2(input_dir.x, -1.0)
	return input_dir


func _handle_movement(delta: float) -> void:
	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	# Read input as a 2D vector (WASD by default)
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	input_dir = _apply_auto_run(input_dir, delta)

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
	is_sprinting = Input.is_action_pressed("sprint") or auto_forward
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
		skeleton.rotation.y = lerp_angle(skeleton.rotation.y, target_yaw, rotation_speed * delta)
	
	move_and_slide()
